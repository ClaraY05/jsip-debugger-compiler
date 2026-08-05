(* Base Set.Tree (vreplay/tests/core_stubs/base__Set.ml): the set's tree with no
   comparator record around it, walked as the set's tree layer alone.
   The two Tree entries share the parents' shapes rather than restating
   them, so a set tree and a set's tree cannot drift apart. *)
module Set = Base__Set

let () =
  let t = Set.Tree.add Set.Tree.empty 2 in
  let t = Set.Tree.add t 1 in
  let t = Set.Tree.add t 3 in
  ignore (t : int Set.Tree.t)
