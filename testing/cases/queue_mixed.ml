(* The rest of the Queue surface: [peek] (a read; fires by design),
   [transfer] (two queue arguments, both mutated, both observed --
   two records in one frame), [clear]. *)
let () =
  let q = Queue.create () in
  Queue.add 1 q;
  Queue.add 2 q;
  ignore (Queue.peek q);
  let q2 = Queue.create () in
  Queue.transfer q q2;
  Queue.clear q2
