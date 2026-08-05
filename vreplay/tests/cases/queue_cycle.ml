(* A payload cycle: the record points back at itself.  The walker's
   within-walk table breaks the cycle with an [Id] back-reference to
   the already-discovered cell, so the dump stays a strict tree and
   the printer needs no guard. *)
type cyc = { name : string; mutable self : cyc option }

let () =
  let r = { name = "loop"; self = None } in
  r.self <- Some r;
  let q = Queue.create () in
  Queue.add r q
