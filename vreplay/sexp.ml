(* A minimal s-expression AST with a sexplib-compatible printer and a
   parser that inverts it, plus the wire schema and its converters.
   No comment syntax; one sexp per string. *)

type t =
  | Atom of string
  | List of t list

(* ---- printing ---- *)

let must_quote s =
  s = ""
  || String.exists
       (fun c ->
         match c with
         | ' ' | '\t' | '\n' | '\r' | '(' | ')' | '"' | ';' | '\\' -> true
         | c -> Char.code c < 32 || Char.code c > 126)
       s

let add_escaped buf s =
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\b' -> Buffer.add_string buf "\\b"
      | c when Char.code c < 32 || Char.code c > 126 ->
        Buffer.add_string buf (Printf.sprintf "\\%03d" (Char.code c))
      | c -> Buffer.add_char buf c)
    s

let rec render buf = function
  | Atom s when must_quote s ->
    Buffer.add_char buf '"';
    add_escaped buf s;
    Buffer.add_char buf '"'
  | Atom s -> Buffer.add_string buf s
  | List xs ->
    Buffer.add_char buf '(';
    List.iteri
      (fun i x ->
        if i > 0 then Buffer.add_char buf ' ';
        render buf x)
      xs;
    Buffer.add_char buf ')'

let to_string x =
  let buf = Buffer.create 256 in
  render buf x;
  Buffer.contents buf

(* ---- parsing ---- *)

let of_string s =
  let n = String.length s in
  let pos = ref 0 in
  let fail msg =
    failwith (Printf.sprintf "Sexp.of_string: %s at %d" msg !pos)
  in
  let is_ws = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false in
  let skip_ws () = while !pos < n && is_ws s.[!pos] do incr pos done in
  let rec parse () =
    skip_ws ();
    if !pos >= n then fail "unexpected end of input";
    match s.[!pos] with
    | '(' -> incr pos; parse_list []
    | ')' -> fail "unexpected )"
    | '"' -> incr pos; parse_quoted (Buffer.create 16)
    | _ -> parse_bare !pos
  and parse_list acc =
    skip_ws ();
    if !pos >= n then fail "unclosed (";
    if s.[!pos] = ')' then begin incr pos; List (List.rev acc) end
    else parse_list (parse () :: acc)
  and parse_quoted buf =
    if !pos >= n then fail "unclosed quote";
    match s.[!pos] with
    | '"' -> incr pos; Atom (Buffer.contents buf)
    | '\\' ->
      incr pos;
      if !pos >= n then fail "unfinished escape";
      (match s.[!pos] with
       | '"' -> Buffer.add_char buf '"'; incr pos
       | '\\' -> Buffer.add_char buf '\\'; incr pos
       | 'n' -> Buffer.add_char buf '\n'; incr pos
       | 't' -> Buffer.add_char buf '\t'; incr pos
       | 'r' -> Buffer.add_char buf '\r'; incr pos
       | 'b' -> Buffer.add_char buf '\b'; incr pos
       | '0' .. '9' ->
         if !pos + 2 >= n then fail "bad numeric escape";
         (match int_of_string_opt (String.sub s !pos 3) with
          | Some d when d <= 255 ->
            Buffer.add_char buf (Char.chr d);
            pos := !pos + 3
          | _ -> fail "bad numeric escape")
       | _ -> fail "unknown escape");
      parse_quoted buf
    | c -> Buffer.add_char buf c; incr pos; parse_quoted buf
  and parse_bare start =
    let stop = function
      | '(' | ')' | '"' -> true
      | c -> is_ws c
    in
    while !pos < n && not (stop s.[!pos]) do incr pos done;
    Atom (String.sub s start (!pos - start))
  in
  let x = parse () in
  skip_ws ();
  if !pos <> n then fail "trailing input";
  x

(* ---- the wire schema ----
   Constructor and field ORDER MUST match runtime/snapshot.c (block
   constructors 0..7 and node fields 0..2 in declaration order).  See
   sexp.mli for the representation mapping these constructors mirror. *)

type block =
  | Int of int
  | Float of float
  | String of string
  | Int32 of int32
  | Int64 of int64
  | Nativeint of nativeint
  | Float_array of float list
  | Address of nativeint

type node = {
  virtual_address : nativeint;
  block : (string * block) list;
  children : node list;
}

type snapshot = {
  ds_type : Data_structure.t;
  root_node : node;
}

(* ---- converters ----
   [to_sexp]/[from_sexp] follow the conventions [@@deriving sexp] would use
   for these type definitions -- records as ((field value) ...) in
   declaration order, constructors as (Name arg) -- so the interface repo
   can mirror the types with ppx_sexp_conv and get its reader for free.
   Addresses print as 0x... atoms, which [Nativeint.of_string] (and hence a
   derived reader) accepts.  [from_sexp] is the exact inverse of [to_sexp];
   it raises [Failure] on a sexp that doesn't have this shape. *)

let hex (a : nativeint) = Printf.sprintf "0x%nx" a

(* Shortest float rendering that still round-trips exactly: 15 significant
   digits when they re-parse to the same double, the always-exact 17
   otherwise.  [Float.of_string] (so a derived reader too) parses both. *)
let fstr f =
  let s = Printf.sprintf "%.15g" f in
  if float_of_string s = f then s else Printf.sprintf "%.17g" f

let sexp_of_block = function
  | Int i -> List [ Atom "Int"; Atom (string_of_int i) ]
  | Float f -> List [ Atom "Float"; Atom (fstr f) ]
  | String s -> List [ Atom "String"; Atom s ]
  | Int32 i -> List [ Atom "Int32"; Atom (Int32.to_string i) ]
  | Int64 i -> List [ Atom "Int64"; Atom (Int64.to_string i) ]
  | Nativeint i -> List [ Atom "Nativeint"; Atom (Nativeint.to_string i) ]
  | Float_array fs ->
    List [ Atom "Float_array"; List (List.map (fun f -> Atom (fstr f)) fs) ]
  | Address a -> List [ Atom "Address"; Atom (hex a) ]

let block_from_sexp = function
  | List [ Atom "Int"; Atom s ] -> Int (int_of_string s)
  | List [ Atom "Float"; Atom s ] -> Float (float_of_string s)
  | List [ Atom "String"; Atom s ] -> String s
  | List [ Atom "Int32"; Atom s ] -> Int32 (Int32.of_string s)
  | List [ Atom "Int64"; Atom s ] -> Int64 (Int64.of_string s)
  | List [ Atom "Nativeint"; Atom s ] -> Nativeint (Nativeint.of_string s)
  | List [ Atom "Float_array"; List fs ] ->
    let flt = function
      | Atom s -> float_of_string s
      | List _ -> failwith "Sexp.from_sexp: bad float"
    in
    Float_array (List.map flt fs)
  | List [ Atom "Address"; Atom a ] -> Address (Nativeint.of_string a)
  | _ -> failwith "Sexp.from_sexp: bad block"

let sexp_of_entry (lbl, b) = List [ Atom lbl; sexp_of_block b ]

let entry_from_sexp = function
  | List [ Atom lbl; b ] -> (lbl, block_from_sexp b)
  | _ -> failwith "Sexp.from_sexp: bad block entry"

(* [seen] guards against a heap cycle surviving the walker's sharing dedup
   (two parents, one node value here): a revisited node is emitted with its
   data but no children, so the printer terminates and a reader can rejoin
   it by address. *)
let rec sexp_of_node seen n =
  let revisit = List.memq n !seen in
  if not revisit then seen := n :: !seen;
  let kids = if revisit then [] else n.children in
  List
    [ List [ Atom "virtual_address"; Atom (hex n.virtual_address) ]
    ; List [ Atom "block"; List (List.map sexp_of_entry n.block) ]
    ; List [ Atom "children"; List (List.map (sexp_of_node seen) kids) ] ]

let rec node_from_sexp = function
  | List
      [ List [ Atom "virtual_address"; Atom a ]
      ; List [ Atom "block"; List entries ]
      ; List [ Atom "children"; List kids ] ] ->
    { virtual_address = Nativeint.of_string a
    ; block = List.map entry_from_sexp entries
    ; children = List.map node_from_sexp kids }
  | _ -> failwith "Sexp.from_sexp: bad node"

(* Event-level: the live weak registry at event time, as (id, current
   address) pairs.  Ids are stable across events; the addresses are
   captured by the same C walk as the nodes, so an [Address a] in the
   snapshot resolves against this event's registry exactly. *)
let sexp_of_registry reg =
  List
    (Array.to_list reg
     |> List.map (fun (id, addr) ->
          List [ Atom (string_of_int id); Atom (hex addr) ]))

let to_sexp { ds_type; root_node } =
  List
    [ List [ Atom "ds_type"; Atom (Data_structure.to_string ds_type) ]
    ; List [ Atom "root_node"; sexp_of_node (ref []) root_node ] ]

let from_sexp = function
  | List
      [ List [ Atom "ds_type"; Atom ds ]
      ; List [ Atom "root_node"; root ] ] ->
    (match Data_structure.of_module ds with
     | Some ds_type -> { ds_type; root_node = node_from_sexp root }
     | None -> failwith "Sexp.from_sexp: unknown ds_type")
  | _ -> failwith "Sexp.from_sexp: bad record"
