(* Stands in for Base's Set: the same unit name and the same
   REPRESENTATION (v0.17's weight-balanced shape), so the CI can walk it
   with no opam switch and no Core installed.  Insertion does not
   rebalance and weights are made up; the wire sees neither. *)

type 'a tree =
  | Empty
  | Leaf of { elt : 'a }
  | Node of
      { left : 'a tree
      ; elt : 'a
      ; right : 'a tree
      ; weight : int
      }

(* holds closures, as Base's does: bookkeeping, never walked *)
type 'a comparator =
  { compare : 'a -> 'a -> int
  ; sexp_of_t : 'a -> string
  }

type 'a t =
  { comparator : 'a comparator
  ; tree : 'a tree
  }

let comparator = { compare = Stdlib.compare; sexp_of_t = (fun _ -> "") }
let empty = { comparator; tree = Empty }

let rec insert tree elt =
  match tree with
  | Empty -> Leaf { elt }
  | Leaf l ->
    let c = Stdlib.compare elt l.elt in
    if c = 0 then tree
    else if c < 0 then
      Node { left = Leaf { elt }; elt = l.elt; right = Empty; weight = 3 }
    else
      Node { left = Empty; elt = l.elt; right = Leaf { elt }; weight = 3 }
  | Node n ->
    let c = Stdlib.compare elt n.elt in
    if c = 0 then tree
    else if c < 0 then Node { n with left = insert n.left elt }
    else Node { n with right = insert n.right elt }

let add t elt = { t with tree = insert t.tree elt }
