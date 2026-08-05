(* Stands in for Core's Doubly_linked: the same unit name and the same
   REPRESENTATION -- a ref holding the head element, elements chained
   CIRCULARLY through [next] (so the walk meets the head again and stops
   at the revisit) with [prev] and the shared [header] bookkeeping. *)

module Header = struct
  type t = { mutable length : int }

  let create () = { length = 1 }
end

module Elt = struct
  type 'a t =
    { mutable value : 'a
    ; mutable prev : 'a t
    ; mutable next : 'a t
    ; mutable header : Header.t
    }

  (* an element starts as a ring of one, as Core's does *)
  let create value header =
    let rec t = { value; prev = t; next = t; header } in
    t
end

type 'a t = 'a Elt.t option ref

let create () : _ t = ref None

(* Core's own returns the element, which is what lets a hash queue index
   its list by key. *)
let insert_last_elt t value =
  match !t with
  | None ->
    let elt = Elt.create value (Header.create ()) in
    t := Some elt;
    elt
  | Some head ->
    let last = head.Elt.prev in
    let elt =
      { Elt.value; prev = last; next = head; header = head.Elt.header }
    in
    last.Elt.next <- elt;
    head.Elt.prev <- elt;
    head.Elt.header.Header.length <- head.Elt.header.Header.length + 1;
    elt

let insert_last t value = ignore (insert_last_elt t value : _ Elt.t)
