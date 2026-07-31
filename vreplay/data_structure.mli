(* The catalogue of data structures visual replay knows how to walk.
   typing/vreplay_instrumentation.ml mirrors these names in [ds_table];
   extend both together when adding a data structure. *)

type t = Map | Set | Queue | Hashtbl

val to_string : t -> string

(* The module name the instrumentation extracted at the call site
   (e.g. "Map") -> the catalogue entry. *)
val of_module : string -> t option

(* One layer of a DS's internal representation.  The walker tells a
   structure's own skeleton apart from the user data it holds by the
   EDGE it reached a block through, never by the block's shape:

   - [Fixed] describes an internal node of one exact size.  [labels]
     name its fields; the [interior] bitmask marks fields that point one
     layer deeper into the structure's own skeleton; the [payload]
     bitmask marks fields holding user data.  Unmarked fields are
     bookkeeping and never reach the wire.
   - [Array_elements] is a variable-size block (an array) every element
     of which is interior, one layer deeper; its fields get numeric
     labels.

   Blocks reached through a payload edge -- and everything below them --
   are user data: every field is kept, labels are numeric, and the DS
   masks never apply.  That is what keeps a user tuple from being
   truncated or mislabeled as a DS node, whatever its arity. *)
type layer =
  | Fixed of
      { labels : string list
      ; interior : int
      ; payload : int
      }
  | Array_elements

(* The layers of one DS, root first, in the order interior edges meet
   them.  Nonempty; once the walk has stepped past the last layer, the
   last layer repeats (an interior chain -- Map's l/r spine, a bucket
   list's next -- keeps its own layer forever). *)
val layout : t -> layer list
