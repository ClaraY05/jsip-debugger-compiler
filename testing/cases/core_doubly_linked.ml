(* Core Doubly_linked (testing/mock/core__Doubly_linked.ml): a ref over
   elements chained circularly.  The last element's [next] is the head
   again -- already walked, so it lands as a second parent of the head's
   node rather than looping forever. *)
module Doubly_linked = Core__Doubly_linked

let () =
  let l = Doubly_linked.create () in
  Doubly_linked.insert_last l "a";
  Doubly_linked.insert_last l "b";
  Doubly_linked.insert_last l "c"
