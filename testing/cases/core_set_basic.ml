(* Base/Core Set (testing/mock/base__Set.ml): the same wrapper record as
   the map, over one-payload Leaf/Node blocks. *)
module Set = Base__Set

let () =
  let s = Set.add Set.empty "b" in
  let s = Set.add s "a" in
  ignore (Set.add s "c")
