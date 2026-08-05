(* stdlib Dynarray: an unboxed Pack of {length; arr; dummy}, so the
   value IS that record.  [arr] keeps room past [length] filled with the
   dummy; only the live prefix reaches the wire. *)
let () =
  let d = Dynarray.create () in
  Dynarray.add_last d "a";
  Dynarray.add_last d "b";
  Dynarray.add_last d "c";
  ignore (Dynarray.pop_last d)
