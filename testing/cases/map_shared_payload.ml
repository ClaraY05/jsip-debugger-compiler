(* One record bound under two keys.  Its first dump happens at the
   inner [add]'s event; every later occurrence -- the second key's slot
   in the outer event, the third version's slot -- is an [Id] reference
   to that single definition, so the reader can tell the slots hold the
   SAME value, not equal copies. *)
module M = Map.Make (String)

type point = { x : int; y : int }

let () =
  let p = { x = 1; y = 2 } in
  let m = M.add "q" p (M.add "p" p M.empty) in
  ignore (M.add "r" p m)
