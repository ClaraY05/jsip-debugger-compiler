(* Base Map.Tree (vreplay/tests/core_stubs/base__Map.ml): the map's tree held with
   no comparator record around it.  It is declared beside the map and
   shares its compilation unit, so the [Tree] component of the type's
   path is the only thing telling the two apart -- and what reaches the
   wire is the map's tree layer with the root record dropped, not a map
   whose first field happens to be a node. *)
module Map = Base__Map

let () =
  let t = Map.Tree.set Map.Tree.empty ~key:"b" ~data:2 in
  let t = Map.Tree.set t ~key:"a" ~data:1 in
  let t = Map.Tree.set t ~key:"c" ~data:3 in
  ignore (t : (string, int) Map.Tree.t)
