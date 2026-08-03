(* Base/Core Hashtbl (testing/mock/base__Hashtbl.ml): record -> bucket
   ARRAY -> AVL tree, three layers deep, where the stdlib's buckets are
   a chain.  Node and Leaf differ in size AND tag. *)
module Hashtbl = Base__Hashtbl

let () =
  let t = Hashtbl.create ~size:4 () in
  Hashtbl.set t ~key:"a" ~data:1;
  Hashtbl.set t ~key:"b" ~data:2;
  Hashtbl.set t ~key:"c" ~data:3
