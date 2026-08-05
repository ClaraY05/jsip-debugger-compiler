(* Stands in for Core's Bag, whose representation IS a doubly-linked
   list: core's bag.ml includes Doubly_linked behind an ASCRIPTION,
   which keeps the representation and seals the type -- a bag is not
   interchangeable with a list, and its own unit declares its [t].  That
   is why the catalogue names Bag on the type side as well as the
   function side; the real library seals into Bag's _intf unit, which is
   named there too. *)

module type S = sig
  type 'a t

  val create : unit -> 'a t
  val insert_last_elt : 'a t -> 'a -> 'a Core__Doubly_linked.Elt.t
end

include (Core__Doubly_linked : S)

(* Core's [add] hands back the element it made, so a caller can remove
   it in O(1) later.  That element type is not one the catalogue claims
   -- claiming it would mean a whole structure per insertion -- so the
   only root this call has is the bag. *)
let add t value = insert_last_elt t value
