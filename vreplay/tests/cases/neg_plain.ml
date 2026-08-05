(* Negative: no data-structure calls at all -> the dump is empty. *)
let g x = x + 1
let f x = x + 2
let () = ignore (f (g 1))
