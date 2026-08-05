(* A list in a data slot.  The schema for [int list] is a single
   self-referential entry -- field 0 is the element, field 1 is the
   same entry again -- so the cells come out labelled [hd]/[tl] all the
   way down the chain, and the nil terminator stays the int 0.  Without
   the schema every cell would be numbered 0/1 like any other block. *)
module M = Map.Make (String)

let () = ignore (M.add "xs" [ 1; 2; 3 ] M.empty)
