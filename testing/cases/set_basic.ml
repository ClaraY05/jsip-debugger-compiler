(* Set mirror of map_basic: add/add/remove fire, [mem] doesn't. *)
module S = Set.Make (Int)

let () =
  let s = S.add 1 S.empty in
  let s = S.add 2 s in
  let s = S.remove 1 s in
  ignore (S.mem 2 s)
