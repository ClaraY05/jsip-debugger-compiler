(* The canonical positive case: add/add/remove fire (3 events);
   [empty] (an ident), [find] (returns the value) and [ignore] don't. *)
module M = Map.Make (String)

let () =
  let m = M.empty in
  let m = M.add "a" 1 m in
  let m = M.add "b" 2 m in
  let m = M.remove "a" m in
  ignore (M.find "b" m)
