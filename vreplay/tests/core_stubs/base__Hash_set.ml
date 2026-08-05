(* Stands in for Base's Hash_set, whose [t] IS a [Hashtbl.t] with unit
   values.  Nothing here has a representation of its own: the point of
   the mock is that a root's type resolves to the Hashtbl unit while the
   MODULE the call went through is what makes the catalogue call it a
   hash set (see [ds_table]'s overrides). *)

type 'a t = ('a, unit) Base__Hashtbl.t

let create ?size () : _ t = Base__Hashtbl.create ?size ()
let add t key = Base__Hashtbl.set t ~key ~data:()
