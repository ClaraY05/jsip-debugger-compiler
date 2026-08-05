(* Version chains share their spines: each [add] dumps only the rebuilt
   path plus [Id] references into earlier versions' blocks.  [grow]
   returns only the last version, so the intermediates' ROOTS die at
   the full major collection -- but their interior blocks live on
   inside [m], and the final [add] must keep referencing those ids
   rather than re-dump the shared spine. *)
module M = Map.Make (String)

let grow () =
  let m1 = M.add "b" 2 (M.add "a" 1 M.empty) in
  let m2 = M.add "c" 3 m1 in
  M.add "d" 4 m2

let () =
  let m = grow () in
  Gc.full_major ();
  ignore (M.add "e" 5 m)
