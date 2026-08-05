(* [fold] whose accumulator is a map is itself an event (its result
   type's head constructor is declared in Stdlib__Map), and the
   closure's [add] calls fire nested inside its frame.  The multi-line
   closure also exercises escaping of newlines in the args field. *)
module M = Map.Make (String)

let () =
  let m = M.add "a" 1 (M.add "b" 2 M.empty) in
  let doubled =
    M.fold
      (fun k v acc ->
        M.add k (v * 2) acc)
      m M.empty
  in
  ignore (M.find "a" doubled)
