(* Base/Core Map (testing/mock/base__Map.ml): a {comparator; tree}
   record over Leaf/Node blocks of different sizes -- the comparator
   holds closures and never reaches the wire, and the two tree shapes
   are what a one-shape layer could not describe. *)
module Map = Base__Map

let () =
  let m = Map.set Map.empty ~key:"b" ~data:2 in
  let m = Map.set m ~key:"a" ~data:1 in
  let m = Map.set m ~key:"c" ~data:3 in
  ignore (Map.remove m "a")
