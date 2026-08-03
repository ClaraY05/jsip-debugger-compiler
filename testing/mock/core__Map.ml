(* The OTHER representation the Core_map layout accepts: Base v0.16's,
   whose root carried a [length] and whose tree was AVL with tuple
   constructors rather than inline records.  Real [Core.Map.t] is an
   alias of [Base.Map.t] -- the unit is reused here because a layout
   accepting BOTH shapes is exactly the point, and a golden test of the
   older one needs a second unit the catalogue names Core_map. *)

type ('k, 'v) tree =
  | Empty
  | Leaf of 'k * 'v
  | Node of ('k, 'v) tree * 'k * 'v * ('k, 'v) tree * int

type 'k comparator =
  { compare : 'k -> 'k -> int
  ; sexp_of_t : 'k -> string
  }

type ('k, 'v) t =
  { comparator : 'k comparator
  ; tree : ('k, 'v) tree
  ; length : int
  }

let comparator = { compare = Stdlib.compare; sexp_of_t = (fun _ -> "") }
let empty = { comparator; tree = Empty; length = 0 }

let rec insert tree key data =
  match tree with
  | Empty -> Leaf (key, data)
  | Leaf (k, d) ->
    let c = Stdlib.compare key k in
    if c = 0 then Leaf (key, data)
    else if c < 0 then Node (Leaf (key, data), k, d, Empty, 2)
    else Node (Empty, k, d, Leaf (key, data), 2)
  | Node (l, k, d, r, h) ->
    let c = Stdlib.compare key k in
    if c = 0 then Node (l, key, data, r, h)
    else if c < 0 then Node (insert l key data, k, d, r, h)
    else Node (l, k, d, insert r key data, h)

let set t ~key ~data =
  { t with tree = insert t.tree key data; length = t.length + 1 }
