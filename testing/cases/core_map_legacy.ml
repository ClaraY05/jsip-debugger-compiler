(* The same catalogue entry over Base v0.16's shape
   (testing/mock/core__Map.ml): a three-field root and AVL tuple nodes.
   One layout describes both because its layers list every shape they
   accept -- a library version bump does not have to move the wire. *)
module Map = Core__Map

let () =
  let m = Map.set Map.empty ~key:"b" ~data:2 in
  let m = Map.set m ~key:"a" ~data:1 in
  ignore (Map.set m ~key:"c" ~data:3)
