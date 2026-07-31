(* Unit tests for the weak registry inside vreplay/vreplay.ml, driven
   through its public entry point [Vreplay.snapshot] (the registry is
   deliberately private): ids are per-object and stable, retired ids are
   never reused, the echoed registry lists the live tracked objects in
   insertion order, a collected object's entry is dropped at the next
   event, tracking never keeps an object alive, and an entry's NAME is
   the latest non-empty identifier the object was observed under
   (anonymous entries stay two-atom on the wire).

   The runner points VREPLAY_FILE at a scratch file; the sink writes are
   unbuffered, so each assertion can re-read the dump mid-run. *)

module M = Map.Make (String)

let dump =
  match Sys.getenv_opt "VREPLAY_FILE" with
  | Some p -> p
  | None -> failwith "run me via testing/run_unit_tests.sh (VREPLAY_FILE unset)"

let snap ?(ds = "Map") ?(name = "") v =
  Vreplay.snapshot ~loc:("test_registry.ml", 1, 0, 1)
    ~fn:("Function_name", "T.probe") ~ds ~args:[] ~name v

(* one registry entry: (id, address, name) -- name "" for the two-atom
   anonymous shape *)
type ev = { id : int; reg : (int * nativeint * string) list; body : Vreplay.t }

let parse_event line =
  match Sexp.of_string line with
  | Sexp.List
      [ Sexp.Atom "event"
      ; Sexp.List [ Sexp.Atom "id"; Sexp.Atom id ]
      ; Sexp.List [ Sexp.Atom "loc"; _ ]
      ; Sexp.List [ Sexp.Atom "fn"; _ ]
      ; Sexp.List [ Sexp.Atom "args"; _ ]
      ; Sexp.List [ Sexp.Atom "registry"; Sexp.List reg ]
      ; Sexp.List [ Sexp.Atom "snapshot"; body ] ] ->
    let entry = function
      | Sexp.List [ Sexp.Atom i; Sexp.Atom a ] ->
        (int_of_string i, Nativeint.of_string a, "")
      | Sexp.List [ Sexp.Atom i; Sexp.Atom a; Sexp.Atom n ] ->
        (int_of_string i, Nativeint.of_string a, n)
      | _ -> failwith "bad registry entry"
    in
    { id = int_of_string id
    ; reg = List.map entry reg
    ; body = Vreplay.from_sexp body
    }
  | _ -> failwith "not an event record"

let events () =
  let ic = open_in_bin dump in
  let rec go acc =
    match input_line ic with
    | line -> go (parse_event line :: acc)
    | exception End_of_file ->
      close_in ic;
      List.rev acc
  in
  go []

let count () = List.length (events ())

let last () =
  match List.rev (events ()) with
  | e :: _ -> e
  | [] -> failwith "no events yet"

let reg_ids e = List.map (fun (i, _, _) -> i) e.reg
let reg_names e = List.map (fun (_, _, n) -> n) e.reg
let reg_addr id e =
  let _, a, _ = List.find (fun (i, _, _) -> i = id) e.reg in
  a

let show_ids ids = String.concat "," (List.map string_of_int ids)
let show_names ns = String.concat "," ns

(* module-global holders keep tracked values alive; overwriting one is
   the only way a value dies here *)
let h1 : int M.t ref = ref M.empty
let h2 : int M.t ref = ref M.empty
let h3 : int M.t ref = ref M.empty
let q : int M.t Queue.t = Queue.create ()

(* built behind a function call so the maps are heap values born at
   runtime, never statically shared *)
let build k v = M.add k v M.empty

(* overwrite dead stack slots so a dropped value is not accidentally
   rooted by a stale frame when we force a collection; deliberately
   non-tail so real frames pile up over the old ones *)
let churn () =
  let rec go n = if n = 0 then 0 else 1 + go (n - 1) in
  ignore (go 1000)

let rec leaves n =
  List.map snd n.Vreplay.block
  @ List.concat_map leaves n.Vreplay.children

let () =
  h1 := build "one" 1;
  snap ~name:"m_one" !h1;
  let e1 = last () in
  Tap.check_eq "first tracked object gets id 1" string_of_int e1.id 1;
  Tap.check "registry echoes the root at its node address"
    (e1.reg = [ (1, e1.body.root_node.virtual_address, "m_one") ]);

  snap !h1;
  let e2 = last () in
  Tap.check_eq "same object again: same id" string_of_int e2.id 1;
  Tap.check_eq "same object again: registry unchanged" show_ids (reg_ids e2)
    [ 1 ];
  Tap.check_eq "anonymous re-observation does not erase the name"
    show_names (reg_names e2) [ "m_one" ];

  (* identity is per OBJECT: observing the same value under another ds
     name neither re-registers nor forks the id *)
  snap ~ds:"Set" !h1;
  let e3 = last () in
  Tap.check_eq "same object under another ds type: same id" string_of_int
    e3.id 1;

  snap ~name:"m_renamed" !h1;
  let e4 = last () in
  Tap.check_eq "latest non-empty name wins (entry renamed)" show_names
    (reg_names e4) [ "m_renamed" ];

  h2 := build "two" 2;
  snap ~name:"m_two" !h2;
  let e5 = last () in
  Tap.check_eq "second object: fresh id" string_of_int e5.id 2;
  Tap.check_eq "registry lists both, in insertion order" show_ids
    (reg_ids e5) [ 1; 2 ];
  Tap.check "new root also echoed at its node address"
    (reg_addr 2 e5 = e5.body.root_node.virtual_address);

  Queue.add !h2 q;
  snap ~ds:"Queue" q;
  let e6 = last () in
  Tap.check_eq "queue joins with the next fresh id" string_of_int e6.id 3;
  Tap.check_eq "registry now tracks all three" show_ids (reg_ids e6)
    [ 1; 2; 3 ];
  Tap.check_eq "never-named entry stays anonymous" show_names
    (reg_names e6) [ "m_renamed"; "m_two"; "" ];
  Tap.check "tracked structure inside the queue is an (Id 2) boundary"
    (List.mem (Vreplay.Id 2) (leaves e6.body.root_node));
  Tap.check "the inner map's data is NOT walked inline"
    (not (List.mem (Vreplay.String "two") (leaves e6.body.root_node)));

  (* drop h1's map; a full collection must clear its weak entry and the
     next event must shed id 1 *)
  h1 := M.empty;
  churn ();
  Gc.full_major ();
  Gc.full_major ();
  snap !h2;
  let e7 = last () in
  Tap.check_eq "re-observing a live object keeps its id" string_of_int
    e7.id 2;
  Tap.check_eq
    "collected object dropped from the registry (weak, non-pinning)"
    show_ids (reg_ids e7) [ 2; 3 ];

  h3 := build "three" 3;
  snap !h3;
  let e8 = last () in
  Tap.check_eq "a retired id is never reused: next object gets 4"
    string_of_int e8.id 4;
  Tap.check_eq "registry keeps insertion order across compaction" show_ids
    (reg_ids e8) [ 2; 3; 4 ];

  (* observations that must NOT append an event *)
  let before = count () in
  snap M.empty;
  Tap.check "immediate root: no event, no registration" (count () = before);
  snap ~ds:"Rope" !h2;
  Tap.check "unknown ds name: no event" (count () = before);
  snap ~ds:"Stack" !h2;
  Tap.check "ds without a catalogue layout: no event" (count () = before);

  Tap.check_eq "total events emitted" string_of_int (count ()) 8;
  Tap.finish ()
