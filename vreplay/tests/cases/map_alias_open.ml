(* Classification reads declaring units off uids, which [Subst] copies
   verbatim -- so events survive module aliasing and [open]. *)
module M = Map.Make (String)
module Alias = M
open Alias

let () = ignore (add "k" 0 empty)
