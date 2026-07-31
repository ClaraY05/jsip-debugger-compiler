(* [transfer q q] names the same queue twice: argument roots are deduped
   by path, so the transfer frame carries ONE record, not two.  (stdlib
   [transfer] onto itself ends with [clear], so the record shows an
   empty queue.) *)
let () =
  let q = Queue.create () in
  Queue.add 1 q;
  Queue.transfer q q
