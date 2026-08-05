(* Queue is mutable: [create] roots at the result, everything else at
   the queue argument, re-read after the call.  The id stays 1
   throughout -- one structure, mutated in place.  [pop] fires too
   (reads and writes are indistinguishable by type, and re-observing
   beats missing a mutation). *)
let () =
  let q = Queue.create () in
  Queue.add "x" q;
  Queue.add "y" q;
  Queue.push "z" q;
  ignore (Queue.pop q)
