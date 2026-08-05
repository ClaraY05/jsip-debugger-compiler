(* Stands in for Base's Stack: the same unit name and the same
   REPRESENTATION -- a preallocated array holding the stack bottom-first
   in slots 0 .. length-1, so the window has to walk it backwards for
   the wire to read top-first the way a list-backed stack does. *)

type 'a t =
  { mutable length : int
  ; mutable elts : 'a array
  }

let none : 'a = Obj.magic 0
let create ?(capacity = 4) () = { length = 0; elts = Array.make capacity none }

let push t x =
  t.elts.(t.length) <- x;
  t.length <- t.length + 1

let pop t =
  match t.length with
  | 0 -> None
  | _ ->
    t.length <- t.length - 1;
    let x = t.elts.(t.length) in
    t.elts.(t.length) <- none;
    Some x
