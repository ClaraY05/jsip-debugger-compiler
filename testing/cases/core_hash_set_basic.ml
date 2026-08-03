(* Base/Core Hash_set (testing/mock/base__Hash_set.ml): the values ARE
   a Hashtbl's -- same record, same bucket array, same AVL trees, with
   unit for every value -- but the type is the hash set's own, so the
   catalogue walks it as Core_hash_set and the interface can render it
   as a set of keys rather than a table of "() " values. *)
module Hash_set = Base__Hash_set

let () =
  let hs = Hash_set.create ~size:4 () in
  Hash_set.add hs "a";
  Hash_set.add hs "b";
  Hash_set.add hs "c"
