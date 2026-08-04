(* A program's own module called [Tree] is still the program's own.
   Telling [Map.Tree] from [Map] means qualifying a type by the module
   its path runs through, and [Elt], [Tree] and [Key] are names any
   program may use -- so the qualifier applies only to units the
   catalogue already knows.  This record keeps its derived schema and is
   not mistaken for a library tree. *)
module Tree = struct
  type t =
    { label : string
    ; size : int
    }
end

let () =
  let node = { Tree.label = "root"; size = 3 } in
  ignore (node : Tree.t)
