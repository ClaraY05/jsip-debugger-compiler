(* Negative: a user module named [Map] shadows the stdlib one.
   Classification reads the DECLARING UNIT off the called value's uid --
   these calls resolve to this unit, not Stdlib__Map, so nothing fires
   even though the names look identical.  Empty dump. *)
module Map = struct
  let empty = []
  let add k v m = (k, v) :: m
  let remove k m = List.filter (fun (k', _) -> k' <> k) m
end

let () =
  let m = Map.add "a" 1 Map.empty in
  ignore (Map.remove "a" m)
