(* Core Fdeque (testing/mock/core__Fdeque.ml): {front; back; length}
   over two ordinary lists, both walked with the same cell layer.
   Immutable, so each call observes only what it returns. *)
module Fdeque = Core__Fdeque

let () =
  let d = Fdeque.enqueue_back Fdeque.empty 1 in
  let d = Fdeque.enqueue_back d 2 in
  let d = Fdeque.enqueue_front d 0 in
  ignore (Fdeque.dequeue_front d)
