(* An instrumented call inside an instrumented call's argument list:
   the inner event lands at depth 2, inside the outer event's frame. *)
module M = Map.Make (String)

let () = ignore (M.add "outer" 1 (M.add "inner" 2 M.empty))
