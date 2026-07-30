(* Negative: a partial application leaves an arrow (no event), and
   completing it through a local ident is an accepted miss -- the
   ident's uid belongs to this unit, not Stdlib__Map.  Empty dump. *)
module M = Map.Make (String)

let () =
  let f = M.add "a" 1 in
  ignore (f M.empty)
