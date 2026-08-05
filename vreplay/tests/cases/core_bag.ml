(* Core Bag (core_stubs/core__Bag.ml): a doubly-linked list under
   another name -- core's bag.ml includes Doubly_linked wholesale, so a
   bag carries that type and walks with its layout while the calls are
   Bag's own.  [add] hands back the element it made, and the catalogue
   deliberately does not claim that type: one element structure per
   insertion would be one structure per insertion.  So every call here
   has exactly one root, the bag itself. *)
module Bag = Core__Bag

let () =
  let b = Bag.create () in
  let _ = Bag.add b "a" in
  let _ = Bag.add b "b" in
  let _ = Bag.add b "c" in
  ()
