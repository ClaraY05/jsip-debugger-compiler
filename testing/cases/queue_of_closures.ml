(* A function value inside a tracked structure: closures (like objects,
   lazy blocks and continuations) carry raw words in their leading
   fields, so the walker must not descend into them -- the closure
   arrives as an opaque (Address _) leaf.  Used to segfault. *)
let () =
  let q = Queue.create () in
  Queue.add (fun x -> x + 1) q;
  Queue.add (fun x -> x * 2) q
