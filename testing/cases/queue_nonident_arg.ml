(* A mutable-module call whose structure argument is NOT a plain ident:
   only an ident is safe to re-read post-call, so [List.hd qs] is
   skipped as a root, and with no roots the [add] is no event at all.
   The one event here is [create] (a structure result).  The [length]
   read never has roots either -- non-ident argument, int result. *)
let () =
  let qs = [ Queue.create () ] in
  Queue.add 1 (List.hd qs);
  ignore (Queue.length (List.hd qs))
