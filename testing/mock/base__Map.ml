(* Stands in for Base's Map: the same unit name and the same
   REPRESENTATION, so the instrumentation classifies calls to it exactly
   as it does the real thing and the walker meets exactly what real Base
   hands over -- in a test the CI can run with no opam switch and no
   Core installed.  Only the shape is faithful: insertion does not
   rebalance and weights are made up, neither of which the wire sees.

   This is Base v0.17's weight-balanced shape.  The OTHER shape the
   Core_map layout accepts, Base v0.16's, is in core__Map.ml. *)

type ('k, 'v) tree =
  | Empty
  | Leaf of
      { key : 'k
      ; data : 'v
      }
  | Node of
      { left : ('k, 'v) tree
      ; key : 'k
      ; data : 'v
      ; right : ('k, 'v) tree
      ; weight : int
      }

(* holds closures, as Base's does: bookkeeping, never walked *)
type 'k comparator =
  { compare : 'k -> 'k -> int
  ; sexp_of_t : 'k -> string
  }

type ('k, 'v) t =
  { comparator : 'k comparator
  ; tree : ('k, 'v) tree
  }

let comparator = { compare = Stdlib.compare; sexp_of_t = (fun _ -> "") }
let empty = { comparator; tree = Empty }

let rec insert tree key data =
  match tree with
  | Empty -> Leaf { key; data }
  | Leaf l ->
    let c = Stdlib.compare key l.key in
    if c = 0 then Leaf { key; data }
    else if c < 0 then
      Node { left = Leaf { key; data }
           ; key = l.key
           ; data = l.data
           ; right = Empty
           ; weight = 3 }
    else
      Node { left = Empty
           ; key = l.key
           ; data = l.data
           ; right = Leaf { key; data }
           ; weight = 3 }
  | Node n ->
    let c = Stdlib.compare key n.key in
    if c = 0 then Node { n with data }
    else if c < 0 then Node { n with left = insert n.left key data }
    else Node { n with right = insert n.right key data }

let set t ~key ~data = { t with tree = insert t.tree key data }

let rec remove_tree tree key =
  match tree with
  | Empty -> Empty
  | Leaf l -> if Stdlib.compare key l.key = 0 then Empty else tree
  | Node n ->
    let c = Stdlib.compare key n.key in
    if c < 0 then Node { n with left = remove_tree n.left key }
    else if c > 0 then Node { n with right = remove_tree n.right key }
    else n.left

let remove t key = { t with tree = remove_tree t.tree key }

(* The bare tree, with no comparator record around it -- what a caller
   holds when the comparator lives elsewhere.  Base declares it beside
   the map and it shares the map's compilation unit, so the [Tree] in
   the path is the only thing telling the two apart. *)
module Tree = struct
  type ('k, 'v) t = ('k, 'v) tree

  (* Base's .mli keeps this type abstract, so a caller never sees the
     alias and the type of a tree is always written [Map.Tree.t].  The
     annotations here say the same thing without an .mli: without them
     inference reports the raw [Base__Map.tree], which resolves to the
     map itself. *)
  let empty : _ t = Empty
  let set (t : _ t) ~key ~data : _ t = insert t key data
end
