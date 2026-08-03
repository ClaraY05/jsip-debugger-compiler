(* Hides the representation the way Base's own .mli does, so a hash set
   resolves to THIS unit rather than to the Hashtbl one it is made of --
   which is what makes it walkable as a set instead of a table. *)

type 'a t

val create : ?size:int -> unit -> 'a t
val add : 'a t -> 'a -> unit
