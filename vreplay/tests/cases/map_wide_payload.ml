(* Payload wider than the DS node: a 5-tuple map value keeps all five
   fields.  (It used to lose its fifth field to the map mask and get
   labeled l/v/d/r, impersonating an interior map node.) *)
module M = Map.Make (String)

let () = ignore (M.add "k" (10, 20, 30, 40, 50) M.empty)
