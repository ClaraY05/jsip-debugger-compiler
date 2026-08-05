(* Stands in for Base's Hashtbl: the same unit name and the same
   REPRESENTATION -- a record over a bucket ARRAY of AVL TREES, not the
   chain the stdlib's buckets hold.  Constructor order matters as much
   as field order: [Node] before [Leaf], as Base declares them, is what
   puts a node at tag 0 and a leaf at tag 1. *)

type ('k, 'v) avltree =
  | Empty
  | Node of
      { mutable left : ('k, 'v) avltree
      ; key : 'k
      ; mutable value : 'v
      ; mutable height : int
      ; mutable right : ('k, 'v) avltree
      }
  | Leaf of
      { key : 'k
      ; mutable value : 'v
      }

(* holds closures, as Base's does: bookkeeping, never walked *)
type 'k hashable =
  { hash : 'k -> int
  ; compare : 'k -> 'k -> int
  }

type ('k, 'v) t =
  { mutable table : ('k, 'v) avltree array
  ; mutable length : int
  ; growth_allowed : bool
  ; hashable : 'k hashable
  ; mutable iteration : int
  }

let create ?(size = 4) () =
  { table = Array.make size Empty
  ; length = 0
  ; growth_allowed = true
  ; hashable = { hash = Hashtbl.hash; compare = Stdlib.compare }
  ; iteration = 0
  }

let rec insert tree key data =
  match tree with
  | Empty -> Leaf { key; value = data }
  | Leaf l ->
    let c = Stdlib.compare key l.key in
    if c = 0 then (l.value <- data; tree)
    else if c < 0 then
      Node { left = Leaf { key; value = data }
           ; key = l.key
           ; value = l.value
           ; height = 2
           ; right = Empty }
    else
      Node { left = Empty
           ; key = l.key
           ; value = l.value
           ; height = 2
           ; right = Leaf { key; value = data } }
  | Node n ->
    let c = Stdlib.compare key n.key in
    if c = 0 then (n.value <- data; tree)
    else if c < 0 then (n.left <- insert n.left key data; tree)
    else (n.right <- insert n.right key data; tree)

let set t ~key ~data =
  let slot = Hashtbl.hash key mod Array.length t.table in
  t.table.(slot) <- insert t.table.(slot) key data;
  t.length <- t.length + 1
