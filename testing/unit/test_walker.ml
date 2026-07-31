(* Unit tests for the C walker [caml_wire_traverse] (runtime/snapshot.c):
   the layered interior/payload mask machinery, size-mismatch demotion,
   layer chaining, boundaries against [known], leaf decoding, sharing,
   cycles, and the registry echo.  The external is redeclared here by C
   name -- the same declaration vreplay.ml keeps private -- so the
   walker is exercised directly, with no compiler pass and no emit path
   in the way. *)

open Vreplay

external traverse :
  Obj.t -> (Obj.t * int) array -> (string array * int * int * bool) array
  -> node * (int * nativeint) array
  = "caml_wire_traverse"

(* the runtime catalogue's layouts, flattened exactly the way
   [Vreplay.snapshot] flattens them before the call *)
let flatten = function
  | Data_structure.Fixed { labels; interior; payload } ->
    (Array.of_list labels, interior, payload, false)
  | Data_structure.Array_elements -> ([||], 0, 0, true)

let layers_of ds = Array.of_list (List.map flatten (Data_structure.layout ds))
let map_layers = layers_of Data_structure.Map
let queue_layers = layers_of Data_structure.Queue

let no_layers : (string array * int * int * bool) array = [||]
let no_known : (Obj.t * int) array = [||]
let labels n = List.map fst n.block
let field l n = List.assoc l n.block
let show_labels = String.concat ","

module M = Map.Make (String)

(* --- the Map layout: interior fields become children, payload fields
   stay data, bookkeeping (h) never reaches the wire --- *)

let () =
  (* add "a" last so the AVL root is the "b" node with an "a" left child *)
  let m = M.add "a" 1 (M.add "b" 2 M.empty) in
  let root, echo = traverse (Obj.repr m) no_known map_layers in
  Tap.check "map: echo empty when nothing is known" (echo = [||]);
  Tap.check_eq "map root: kept data labels" show_labels (labels root)
    [ "v"; "d"; "r" ];
  Tap.check "map root: payload v" (field "v" root = String "b");
  Tap.check "map root: payload d" (field "d" root = Int 2);
  Tap.check "map root: empty interior side is Int 0" (field "r" root = Int 0);
  Tap.check "map root: bookkeeping h masked out"
    (not (List.mem_assoc "h" root.block));
  Tap.check_eq "map root: one interior child" string_of_int
    (List.length root.children) 1;
  let l = List.hd root.children in
  Tap.check_eq "map child: same layer repeats along l/r" show_labels
    (labels l) [ "l"; "v"; "d"; "r" ];
  Tap.check "map child: its own payload" (field "v" l = String "a");
  Tap.check "map child: leaf of the spine" (l.children = []);
  Tap.check "map: node addresses nonzero and distinct"
    (root.virtual_address <> 0n
     && l.virtual_address <> 0n
     && root.virtual_address <> l.virtual_address)

(* --- payload is chosen by EDGE, never by shape --- *)

let () =
  let m = M.add "k" (7, "x", 9) M.empty in
  let root, _ = traverse (Obj.repr m) no_known map_layers in
  match root.children with
  | [ t ] ->
    Tap.check_eq "payload tuple: numeric labels" show_labels (labels t)
      [ "0"; "1"; "2" ];
    Tap.check "payload tuple: values kept"
      (field "0" t = Int 7 && field "1" t = String "x" && field "2" t = Int 9)
  | _ -> Tap.check "payload tuple: exactly one child" false

let () =
  (* same arity as a map Node: must NOT wear the map's labels or masks *)
  let m = M.add "k" (1, 2, 3, 4, 5) M.empty in
  let root, _ = traverse (Obj.repr m) no_known map_layers in
  match root.children with
  | [ t ] ->
    Tap.check_eq "arity-5 payload: all five kept, numeric" show_labels
      (labels t) [ "0"; "1"; "2"; "3"; "4" ]
  | _ -> Tap.check "arity-5 payload: exactly one child" false

(* --- a size-mismatched interior layer demotes the cell to payload
   treatment: keep everything, numeric labels, nothing mislabeled --- *)

let () =
  let m = M.add "a" 1 (M.add "b" 2 M.empty) in
  let wrong = [| ([| "x"; "y"; "z" |], 0b001, 0b110, false) |] in
  let root, _ = traverse (Obj.repr m) no_known wrong in
  Tap.check_eq "demotion: all fields kept with numeric labels" show_labels
    (labels root) [ "1"; "2"; "3"; "4" ];
  Tap.check "demotion: even bookkeeping h is visible" (field "4" root = Int 2);
  (match root.children with
   | [ l ] ->
     Tap.check_eq "demotion: children walk on as payload" show_labels
       (labels l) [ "0"; "1"; "2"; "3"; "4" ]
   | _ -> Tap.check "demotion: one child" false)

(* --- Array_elements: variable size, every element one layer deeper --- *)

let () =
  let arr = [| (10, 20); (30, 40) |] in
  let layers = [| ([||], 0, 0, true); ([| "x"; "y" |], 0, 0b11, false) |] in
  let root, _ = traverse (Obj.repr arr) no_known layers in
  Tap.check "array layer: no data fields, all elements interior"
    (root.block = []);
  match root.children with
  | [ e1; e2 ] ->
    Tap.check_eq "array element: next layer's labels apply" show_labels
      (labels e1) [ "x"; "y" ];
    Tap.check "array element values"
      (field "x" e1 = Int 10 && field "y" e2 = Int 40)
  | _ -> Tap.check "array layer: two children" false

(* --- the last layer repeats along interior chains (Queue cells) --- *)

let () =
  let q = Queue.create () in
  Queue.add 10 q;
  Queue.add 20 q;
  Queue.add 30 q;
  let root, _ = traverse (Obj.repr q) no_known queue_layers in
  Tap.check_eq "queue root: length kept, last dropped as bookkeeping"
    show_labels (labels root) [ "length" ];
  Tap.check "queue root: length value" (field "length" root = Int 3);
  let rec contents n =
    match n.children with
    | [] -> [ field "0" n ]
    | [ next ] -> field "0" n :: contents next
    | _ -> [ Int (-1) ]
  in
  let rec last n = match n.children with [ nx ] -> last nx | _ -> n in
  match root.children with
  | [ c1 ] ->
    Tap.check "queue chain: cell layer repeats down [next]"
      (contents c1 = [ Int 10; Int 20; Int 30 ]);
    Tap.check "queue final cell: Nil next is Int 0" (field "1" (last c1) = Int 0)
  | _ -> Tap.check "queue root: first is the only child" false

(* --- registry boundaries: a known block becomes (Id _), unwalked --- *)

let () =
  let inner = (1, 2) in
  let outer = (inner, 99) in
  let root, echo =
    traverse (Obj.repr outer) [| (Obj.repr inner, 42) |] no_layers
  in
  Tap.check "boundary: known block surfaces as Id" (field "0" root = Id 42);
  Tap.check "boundary: and is not descended into" (root.children = []);
  Tap.check "boundary: sibling payload unaffected" (field "1" root = Int 99);
  (match echo with
   | [| (42, a) |] -> Tap.check "boundary: echoed with its address" (a <> 0n)
   | _ -> Tap.check "boundary: echo shape" false)

let () =
  (* the root itself being known must not collapse the walk to a lone Id:
     vreplay.ml registers the root before walking it *)
  let m = M.add "a" 1 M.empty in
  let root, echo = traverse (Obj.repr m) [| (Obj.repr m, 7) |] map_layers in
  Tap.check "known root: still walked in full" (root.block <> []);
  (match echo with
   | [| (7, a) |] ->
     Tap.check "known root: echoed address IS the root node's address"
       (a = root.virtual_address)
   | _ -> Tap.check "known root: echo shape" false)

let () =
  let x = ref 1 and y = ref 2 and z = ref 3 in
  let known = [| (Obj.repr x, 5); (Obj.repr y, 3); (Obj.repr z, 9) |] in
  let _, echo = traverse (Obj.repr (ref 0)) known no_layers in
  Tap.check_eq "echo preserves registry order (never sorted)"
    (fun l -> show_labels (List.map string_of_int l))
    (List.map fst (Array.to_list echo))
    [ 5; 3; 9 ]

(* --- sharing: one block, one node, several parents --- *)

let () =
  let x = ((9, 9), 1) in
  let pair = (x, x) in
  let root, _ = traverse (Obj.repr pair) no_known no_layers in
  match root.children with
  | [ a; b ] ->
    Tap.check "sharing: both edges reach the SAME node (physical eq)" (a == b);
    Tap.check_eq "sharing: shared node walked once, in full" string_of_int
      (List.length a.children) 1;
    let s =
      Sexp.to_string
        (to_sexp { ds_type = Data_structure.Map; root_node = root })
    in
    let back = from_sexp (Sexp.of_string s) in
    (match back.root_node.children with
     | [ a'; b' ] ->
       Tap.check "sharing: printer emits the revisit childless"
         (List.length a'.children = 1 && b'.children = []);
       Tap.check "sharing: both occurrences keep the address for rejoining"
         (a'.virtual_address = b'.virtual_address);
       Tap.check "sharing: dump round-trips byte-stable"
         (Sexp.to_string (to_sexp back) = s)
     | _ -> Tap.check "sharing: reparse shape" false)
  | _ -> Tap.check "sharing: two children" false

(* --- cycles: the walk terminates and so does the printer --- *)

let () =
  let rec ones = 1 :: ones in
  let root, _ = traverse (Obj.repr ones) no_known no_layers in
  Tap.check "cycle: content captured" (field "0" root = Int 1);
  (match root.children with
   | [ self ] -> Tap.check "cycle: back edge reuses the root node" (self == root)
   | _ -> Tap.check "cycle: one child" false);
  let s =
    Sexp.to_string (to_sexp { ds_type = Data_structure.Map; root_node = root })
  in
  Tap.check "cycle: printer terminates" (String.length s > 0);
  let back = from_sexp (Sexp.of_string s) in
  Tap.check "cycle: dump round-trips byte-stable"
    (Sexp.to_string (to_sexp back) = s)

let () =
  let a = ref 0 and b = ref 0 in
  Obj.set_field (Obj.repr a) 0 (Obj.repr b);
  Obj.set_field (Obj.repr b) 0 (Obj.repr a);
  let root, _ = traverse (Obj.repr a) no_known no_layers in
  match root.children with
  | [ nb ] ->
    (match nb.children with
     | [ na ] ->
       Tap.check "mutual cycle: edge returns to the first node" (na == root)
     | _ -> Tap.check "mutual cycle: b has one child" false)
  | _ -> Tap.check "mutual cycle: a has one child" false

(* --- roots with no cell to walk --- *)

let () =
  let root, echo = traverse (Obj.repr 42) no_known no_layers in
  Tap.check "immediate root: lone (0 (Int 42)) leaf node"
    (root.virtual_address = 0n
     && root.block = [ ("0", Int 42) ]
     && root.children = []);
  Tap.check "immediate root: empty echo" (echo = [||])

let () =
  (* a non-scannable root (here a float array) yields an EMPTY node --
     address only, data dropped.  No catalogue layout roots at one
     today; pinned so a future layout addition trips over this
     knowingly. *)
  let root, _ = traverse (Obj.repr [| 1.5; 2.5 |]) no_known no_layers in
  Tap.check "non-scannable root: empty node, data dropped"
    (root.block = [] && root.children = [] && root.virtual_address <> 0n)

(* --- leaf decoding per the manual's representation tables --- *)

type float_record = { fx : float; fy : float }
type ab = A of int | B of int

let () =
  let base = int_of_string "17" in
  let clos x = x + base in
  let lz = lazy (base + 1) in
  let tup =
    ( "s\000tr"
    , 3.5
    , 42l
    , 43L
    , 44n
    , [| 1.5; 2.5 |]
    , { fx = 9.5; fy = 8.5 }
    , clos
    , lz
    , stdin )
  in
  let root, _ = traverse (Obj.repr tup) no_known no_layers in
  Tap.check "leaf: string keeps embedded NUL" (field "0" root = String "s\000tr");
  Tap.check "leaf: float" (field "1" root = Float 3.5);
  Tap.check "leaf: int32 custom" (field "2" root = Int32 42l);
  Tap.check "leaf: int64 custom" (field "3" root = Int64 43L);
  Tap.check "leaf: nativeint custom" (field "4" root = Nativeint 44n);
  Tap.check "leaf: float array" (field "5" root = Float_array [ 1.5; 2.5 ]);
  Tap.check "leaf: all-float record flattens to Float_array (labels lost)"
    (field "6" root = Float_array [ 9.5; 8.5 ]);
  Tap.check "leaf: closure is an opaque Address"
    (match field "7" root with Address _ -> true | _ -> false);
  Tap.check "leaf: unforced lazy is an opaque Address"
    (match field "8" root with Address _ -> true | _ -> false);
  Tap.check "leaf: unknown custom (a channel) is an opaque Address"
    (match field "9" root with Address _ -> true | _ -> false);
  Tap.check "leaf: none of the ten spawned children" (root.children = []);
  let broot, _ =
    traverse (Obj.repr (Bytes.of_string "b\000b", 0)) no_known no_layers
  in
  Tap.check "leaf: bytes decode as String" (field "0" broot = String "b\000b")

let () =
  let root, _ = traverse (Obj.repr (None, Some 5)) no_known no_layers in
  Tap.check "constant constructor (None) is Int 0" (field "0" root = Int 0);
  (match root.children with
   | [ s ] -> Tap.check "Some 5 is a child node" (s.block = [ ("0", Int 5) ])
   | _ -> Tap.check "Some 5 is a child node" false);
  (* the wire records no block TAG: [A 5] and [B 5] walk identically, so
     the interface cannot tell constructors of the same arity apart.
     Pinned as a known representational gap. *)
  let na, _ = traverse (Obj.repr (A 5)) no_known no_layers in
  let nb, _ = traverse (Obj.repr (B 5)) no_known no_layers in
  Tap.check "variant tag never reaches the wire (known gap)"
    (na.block = nb.block && na.children = [] && nb.children = [])

(* --- mask geometry --- *)

let () =
  (* masks address at most the first word's worth of fields; an all-ones
     payload mask keeps fields 0..63 and silently drops the rest.  Real
     layouts are five fields wide at most -- pinned so the limit is a
     recorded fact, not a surprise. *)
  let b = Obj.new_block 0 65 in
  for i = 0 to 64 do
    Obj.set_field b i (Obj.repr (i * 10))
  done;
  let layer_labels = Array.init 65 string_of_int in
  let root, _ = traverse b no_known [| (layer_labels, 0, -1, false) |] in
  Tap.check_eq "mask width: an all-ones mask keeps exactly 64 fields"
    string_of_int
    (List.length root.block)
    64;
  Tap.check "mask width: field 63 kept, field 64 dropped"
    (List.mem_assoc "63" root.block && not (List.mem_assoc "64" root.block))

let () =
  (* one block first reached through an interior edge, then through a
     payload edge: the FIRST edge fixes its mode, so the interior
     layer's mask applies to both parents' views.  Unreachable with the
     current catalogue (DS skeletons and user data never alias) --
     pinned to keep the rule deliberate. *)
  let shared = (111, 222) in
  let outer = (shared, shared) in
  let layers =
    [| ([| "i"; "p" |], 0b01, 0b10, false)
     ; ([| "a"; "b" |], 0, 0b01, false) |]
  in
  let root, _ = traverse (Obj.repr outer) no_known layers in
  match root.children with
  | [ a; b ] ->
    Tap.check "first edge wins: both edges see one node" (a == b);
    Tap.check_eq "first edge wins: the interior layer's mask applied"
      show_labels (labels a) [ "a" ]
  | _ -> Tap.check "first edge wins: two children" false

let () = Tap.finish ()
