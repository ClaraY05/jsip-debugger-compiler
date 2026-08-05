(* Set-producing operations beyond add/remove: of_list, union, inter
   and diff all return sets, so each is an event. *)
module S = Set.Make (Int)

let () =
  let a = S.of_list [ 1; 2; 3 ] in
  let b = S.of_list [ 3; 4 ] in
  ignore (S.union a b);
  ignore (S.inter a b);
  ignore (S.diff a b)
