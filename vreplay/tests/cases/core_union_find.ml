(* Core Union_find (core_stubs/core__Union_find.ml): an inverted
   forest.  Each node holds a pointer UPWARDS -- [parent] steps back to
   another node's own record, the one place a layout walks backwards --
   until a root carrying the value the class shares.  Nodes united onto
   the same root reach the same record, and the second walk to get there
   says so with an [Id]; asking for a value compresses the path it
   walked, so the last snapshot is flatter than the ones before it. *)
module Union_find = Core__Union_find

let () =
  let a = Union_find.create "a" in
  let b = Union_find.create "b" in
  let c = Union_find.create "c" in
  Union_find.union a b;
  Union_find.union b c;
  ignore (Union_find.get c : string)
