(* Core Deque (testing/mock/core__Deque.ml): a ring buffer whose live
   range starts one past [front_index] and wraps modulo the array's own
   length -- five slots, no mask to land on.  Enqueuing at the front
   walks [front_index] backwards off the start of the array. *)
module Deque = Core__Deque

let () =
  let d = Deque.create ~capacity:5 () in
  Deque.enqueue_back d 1;
  Deque.enqueue_back d 2;
  Deque.enqueue_front d 0;
  Deque.enqueue_back d 3
