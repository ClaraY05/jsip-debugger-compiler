(* The catalogue of data structures visual replay knows how to walk.
   typing/vreplay_instrumentation.ml mirrors these names in [ds_table];
   extend both together when adding a data structure. *)

(* Constructor ORDER is part of the C walker's contract --
   runtime/snapshot.c stores this value verbatim into each wire node
   (see [Vreplay.node]). *)
type t = Map | Set | Queue

val to_string : t -> string

(* The module name the instrumentation extracted at the call site
   (e.g. "Map") -> the catalogue entry. *)
val of_module : string -> t option

(* Per-type layout of the DS's internal node: field labels, and a bitmask
   of the fields that carry meaningful information -- the child pointers
   and the key/value positions.  Bookkeeping fields (e.g. the AVL height
   [h]) are left unmasked and never reach the wire. *)
type layout = { labels : string list; mask : int }

val layout : t -> layout
