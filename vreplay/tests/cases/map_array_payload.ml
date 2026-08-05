(* An array in a data slot, holding a 0.  An array schema keeps every
   slot -- including the ones holding 0, which are ordinary elements
   here and not the empty buckets a hashtable's array is mostly made
   of.  Slots stay numbered: an array has no field names to give. *)
module M = Map.Make (String)

let () = ignore (M.add "a" [| 10; 0; 30 |] M.empty)
