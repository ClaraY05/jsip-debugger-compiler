(* Stands in for Base's Queue: the same unit name and the same
   REPRESENTATION -- a preallocated ring buffer plus the indices that
   bound it, not a linked chain.  Dead slots hold an immediate sentinel,
   as Base's Option_array does; a walk that ignored the window would
   show them, and would show live elements in slot order rather than in
   queue order once the buffer wraps. *)

type 'a t =
  { mutable num_mutations : int
  ; mutable front : int
  ; mutable mask : int
  ; mutable length : int
  ; mutable elts : 'a array
  }

(* Base's [Option_array] none is an immediate too (a polymorphic-variant
   hash); any immediate that is not user data makes the same point. *)
let none : 'a = Obj.magic 0

let create ?(capacity = 4) () =
  { num_mutations = 0
  ; front = 0
  ; mask = capacity - 1
  ; length = 0
  ; elts = Array.make capacity none
  }

let enqueue t x =
  t.elts.((t.front + t.length) land t.mask) <- x;
  t.length <- t.length + 1;
  t.num_mutations <- t.num_mutations + 1

let dequeue t =
  match t.length with
  | 0 -> None
  | _ ->
    let x = t.elts.(t.front) in
    t.elts.(t.front) <- none;
    t.front <- (t.front + 1) land t.mask;
    t.length <- t.length - 1;
    t.num_mutations <- t.num_mutations + 1;
    Some x
