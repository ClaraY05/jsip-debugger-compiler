(* The registry holds structures weakly: the map tracked inside [make]
   is dead once it returns, so after a full major collection the second
   event's registry must not carry its id any more. *)
module M = Map.Make (String)

let make () = ignore (M.add "dead" 0 M.empty)

let () =
  make ();
  Gc.full_major ();
  ignore (M.add "live" 1 M.empty)
