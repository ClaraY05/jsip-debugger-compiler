(* Float-shaped blocks.  A record whose fields are all floats, and a
   float array, are stored as flat runs of unboxed doubles rather than
   blocks of pointers, so the walker refuses to enter them -- reading
   doubles as pointers is how you crash the program being debugged.
   The structural guard therefore runs AHEAD of the schema, whatever
   the type says.

   Reached as a field ([band]) such a block is decoded in place, so it
   keeps both its name and its values.  Reached as the ROOT ([f]) it
   has no enclosing field to be named by, and is decoded as the node's
   sole entry -- which is the whole point: before, a float-shaped root
   produced a node with nothing in it at all.

   [r] is deliberately absent from the dump: an all-float record is a
   representation the schema does not describe, and an undescribable
   binding is left alone rather than dumped unlabelled. *)

type reading = { lo : float; hi : float }

type sample =
  { label : string
  ; band : reading
  }

type readings = float array

let () =
  let r = { lo = 1.5; hi = 2.5 } in
  let s = { label = "a"; band = r } in
  let f : readings = [| 3.5; 4.5 |] in
  ignore (r, s, f)
