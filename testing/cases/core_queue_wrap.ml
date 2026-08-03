(* Base/Core Queue (testing/mock/base__Queue.ml): a ring buffer.  The
   dequeues move [front] far enough that the last enqueues wrap around
   the end of the array -- the wire must still read in queue order, and
   must not show the sentinel in the slots nobody is using. *)
module Queue = Base__Queue

let () =
  let q = Queue.create ~capacity:4 () in
  Queue.enqueue q 1;
  Queue.enqueue q 2;
  Queue.enqueue q 3;
  ignore (Queue.dequeue q);
  ignore (Queue.dequeue q);
  Queue.enqueue q 4;
  Queue.enqueue q 5
