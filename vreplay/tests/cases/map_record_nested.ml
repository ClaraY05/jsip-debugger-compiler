(* A record whose own fields are structured: the schema descends into
   them, so [tags] is described as an array and [span] as a tuple
   rather than both arriving as anonymous numbered blocks.  The tuple
   keeps positional labels -- a tuple has no field names -- which is
   what the empty label in a schema entry means. *)
module M = Map.Make (String)

type trade =
  { price : int
  ; tags : string array
  ; span : int * int
  }

let () =
  ignore
    (M.add "t"
       { price = 101; tags = [| "buy"; "limit" |]; span = (1, 9) }
       M.empty)
