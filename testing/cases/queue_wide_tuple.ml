(* A user tuple inside a queue is payload: every field survives with
   numeric labels, whatever its arity.  (It used to be truncated by the
   queue mask and mislabeled length/first, impersonating a queue root.) *)
let () =
  let q = Queue.create () in
  Queue.add (1, 2, 3) q
