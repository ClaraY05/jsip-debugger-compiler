(* [transfer] mutates both of its queues; both argument roots are
   observed -- q1 emptied, q2 grown -- as two records in one frame. *)
let () =
  let q1 = Queue.create () in
  let q2 = Queue.create () in
  Queue.add 1 q1;
  Queue.add 2 q1;
  Queue.transfer q1 q2
