(* Unit tests for vreplay/sexp.ml: [to_string]'s quoting/escaping rules,
   [of_string] as its exact inverse, parse failures, and the wire
   converters ([to_sexp]/[from_sexp]) on hand-built snapshots -- the
   parts every dump line passes through before the interface repo ever
   sees it. *)

let str (x : string) = x

(* --- printer and parser as exact inverses, atom by atom --- *)

let prints name atom rendered =
  Tap.check_eq (name ^ ": prints") str
    (Sexp.to_string (Sexp.Atom atom)) rendered;
  Tap.check (name ^ ": reparses") (Sexp.of_string rendered = Sexp.Atom atom)

let () =
  prints "bare atom" "abc" "abc";
  prints "empty atom" "" "\"\"";
  prints "space" "a b" "\"a b\"";
  prints "double quote" "a\"b" "\"a\\\"b\"";
  prints "backslash" "a\\b" "\"a\\\\b\"";
  prints "newline" "a\nb" "\"a\\nb\"";
  prints "tab" "a\tb" "\"a\\tb\"";
  prints "carriage return" "a\rb" "\"a\\rb\"";
  prints "backspace" "a\bb" "\"a\\bb\"";
  prints "open paren" "a(b" "\"a(b\"";
  prints "close paren" "a)b" "\"a)b\"";
  prints "semicolon" "a;b" "\"a;b\"";
  prints "control char" "\001" "\"\\001\"";
  prints "nul" "\000" "\"\\000\"";
  prints "del" "\127" "\"\\127\"";
  prints "high byte" "\255" "\"\\255\"";
  (* '{' / '}' are printable non-specials, so they print bare.  Safe
     only because a record line's sexp starts with '(' -- the depth
     markers the reader strips are exclusively LEADING braces. *)
  prints "braces stay bare" "{x}" "{x}"

let () =
  let all = String.init 256 Char.chr in
  Tap.check "all 256 bytes round-trip"
    (Sexp.of_string (Sexp.to_string (Sexp.Atom all)) = Sexp.Atom all)

(* --- lists and parser tolerance --- *)

let () =
  let s =
    Sexp.List
      [ Sexp.Atom "a"; Sexp.List []; Sexp.List [ Sexp.Atom "b c" ] ]
  in
  Tap.check_eq "list rendering" str (Sexp.to_string s) "(a () (\"b c\"))";
  Tap.check "list reparses" (Sexp.of_string "(a () (\"b c\"))" = s);
  Tap.check "surrounding/inner whitespace tolerated"
    (Sexp.of_string "  ( a\n\t( b ) ) "
     = Sexp.List [ Sexp.Atom "a"; Sexp.List [ Sexp.Atom "b" ] ]);
  Tap.check "adjacent quoted atoms need no space"
    (Sexp.of_string "(\"a\"\"b\")"
     = Sexp.List [ Sexp.Atom "a"; Sexp.Atom "b" ]);
  Tap.check "numeric escape parses" (Sexp.of_string "\"\\065\"" = Sexp.Atom "A")

let fails name input =
  Tap.check name
    (match Sexp.of_string input with
     | exception Failure _ -> true
     | _ -> false)

let () =
  fails "empty input fails" "";
  fails "unclosed ( fails" "(a";
  fails "bare ) fails" ")";
  fails "trailing atom fails" "a b";
  fails "trailing ) fails" "(a) )";
  fails "unclosed quote fails" "\"abc";
  fails "unfinished escape fails" "\"a\\";
  fails "unknown escape fails" "\"\\q\"";
  fails "short numeric escape fails" "\"\\26\"";
  fails "numeric escape past 255 fails" "\"\\300\""

(* --- wire converters on hand-built snapshots --- *)

let snap_of_block b =
  { Vreplay.ds_type = Data_structure.Map
  ; root_node =
      { Vreplay.virtual_address = 0n; block = [ ("x", b) ]; children = [] }
  }

let () =
  List.iter
    (fun (name, b) ->
      let line = Sexp.to_string (Vreplay.to_sexp (snap_of_block b)) in
      let back = Vreplay.from_sexp (Sexp.of_string line) in
      Tap.check ("block round-trips: " ^ name) (back = snap_of_block b);
      Tap.check ("block reprint stable: " ^ name)
        (Sexp.to_string (Vreplay.to_sexp back) = line))
    [ ("Int", Vreplay.Int (-42))
    ; ("Int min_int", Vreplay.Int min_int)
    ; ("Float", Vreplay.Float 3.14)
    ; ("String awkward", Vreplay.String "with \"quotes\" \n {braces} \000")
    ; ("Int32 min", Vreplay.Int32 Int32.min_int)
    ; ("Int64 min", Vreplay.Int64 Int64.min_int)
    ; ("Nativeint", Vreplay.Nativeint (-5n))
    ; ("Float_array", Vreplay.Float_array [ 1.5; -0.0; 1e300 ])
    ; ("Address", Vreplay.Address 0x7f001234n)
    ; ("Address high bit", Vreplay.Address (-1n))
    ; ("Id", Vreplay.Id 7) ]

(* floats must survive the wire BIT-exactly, not just approximately *)
let float_exact name f =
  let line = Sexp.to_string (Vreplay.to_sexp (snap_of_block (Vreplay.Float f))) in
  match Vreplay.from_sexp (Sexp.of_string line) with
  | { Vreplay.root_node = { block = [ (_, Vreplay.Float g) ]; _ }; _ } ->
    Tap.check ("float exact: " ^ name)
      (Int64.bits_of_float g = Int64.bits_of_float f)
  | _ -> Tap.check ("float exact: " ^ name) false

let () =
  float_exact "0.1" 0.1;
  float_exact "1/3 (needs 17 digits)" (1. /. 3.);
  float_exact "max_float" max_float;
  float_exact "min_float" min_float;
  float_exact "denormal" 4.9e-324;
  float_exact "negative zero" (-0.0);
  float_exact "infinity" infinity;
  (let line =
     Sexp.to_string (Vreplay.to_sexp (snap_of_block (Vreplay.Float nan)))
   in
   match Vreplay.from_sexp (Sexp.of_string line) with
   | { Vreplay.root_node = { block = [ (_, Vreplay.Float g) ]; _ }; _ } ->
     Tap.check "float exact: nan stays nan" (Float.is_nan g)
   | _ -> Tap.check "float exact: nan stays nan" false)

let sfails name input =
  Tap.check name
    (match Vreplay.from_sexp (Sexp.of_string input) with
     | exception Failure _ -> true
     | _ -> false)

let () =
  sfails "from_sexp: unknown ds_type fails"
    "((ds_type Rope) (root_node ((virtual_address 0x0) (block ()) \
     (children ()))))";
  sfails "from_sexp: node missing children fails"
    "((ds_type Map) (root_node ((virtual_address 0x0) (block ()))))";
  sfails "from_sexp: unknown block constructor fails"
    "((ds_type Map) (root_node ((virtual_address 0x0) \
     (block ((x (Intt 1)))) (children ()))))";
  sfails "from_sexp: non-numeric Int fails"
    "((ds_type Map) (root_node ((virtual_address 0x0) \
     (block ((x (Int zzz)))) (children ()))))"

(* --- the event-wrapper renderers the instrumentation relies on --- *)

let () =
  Tap.check_eq "loc renders in the interface's Location.t shape" str
    (Sexp.to_string (Sexp.sexp_of_loc ("t.ml", 4, 10, 23)))
    "((file_path t.ml) (line_number 4) (char_range (10 23)))";
  Tap.check_eq "fn renders as a Function_info.t constructor" str
    (Sexp.to_string (Sexp.sexp_of_fn ("Function_name", "M.add")))
    "(Function_name M.add)";
  Tap.check_eq "args render as Argument.t constructors" str
    (Sexp.to_string
       (Sexp.sexp_of_args
          [ ("No_label", "", "m"); ("Labelled", "init", "0") ]))
    "((No_label (expression (Unnamed m))) \
     (Labelled (label init) (expression (Unnamed 0))))";
  Tap.check_eq "registry renders as (id addr) pairs" str
    (Sexp.to_string (Sexp.sexp_of_registry [| (1, 0x10n); (2, 0x20n) |]))
    "((1 0x10) (2 0x20))"

let () = Tap.finish ()
