(* Data representations on the wire: float data arrives as (Float _),
   and a tuple value is a scannable block, so it becomes a child node
   of the map node holding it. *)
module M = Map.Make (String)

let () =
  let m = M.add "pi" 3.14 M.empty in
  ignore (M.add "e" 2.71 m);
  ignore (M.add "pair" (1, "one") M.empty)
