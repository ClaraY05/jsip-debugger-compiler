(* A minimal s-expression AST with a sexplib-compatible printer and a
   parser that inverts it.  No comment syntax; one sexp per string. *)

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
