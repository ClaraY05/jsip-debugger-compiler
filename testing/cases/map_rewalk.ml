(* Re-observing an already-dumped immutable structure: stdlib
   [Map.remove] returns the map ITSELF when the key is absent, so the
   second event's root is physically the first's -- it must collapse
   to a revisit stub (same id, current address, empty block and
   children) instead of re-dumping anything. *)
module M = Map.Make (String)

let () =
  let m = M.add "b" 2 (M.add "a" 1 M.empty) in
  ignore (M.remove "zzz" m)
