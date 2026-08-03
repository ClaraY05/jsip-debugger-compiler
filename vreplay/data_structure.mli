(* The catalogue of data structures visual replay knows how to walk.
   typing/vreplay_instrumentation.ml mirrors these names in [ds_table];
   extend both together when adding a data structure. *)

(* [User] is not a container: it is any type the user's own program
   declared, whose shape comes from the schema the instrumentation
   derived rather than from a hand-written layout here. *)
type t = Map | Set | Queue | Hashtbl | User

val to_string : t -> string

(* The module name the instrumentation extracted at the call site
   (e.g. "Map") -> the catalogue entry. *)
val of_module : string -> t option

(* Whether values of this DS never change after creation.  Immutable
   structures' dumped blocks are remembered (weakly) by the runtime so
   later events stop at them with [Id] references and dump only what is
   new; mutable ones are re-walked in full at every event. *)
val is_immutable : t -> bool

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
   them.  Once the walk has stepped past the last layer, the last layer
   repeats (an interior chain -- Map's l/r spine, a bucket list's next
   -- keeps its own layer forever).  Empty only for [User], which has
   no skeleton of its own to describe. *)
val layout : t -> layer list

(* Which payload field of each layer carries which role of the event's
   [ty] -- (field index, role name), one list per layer of [layout].
   A map's node holds its key in [v] and its data in [d]; a queue cell
   holds its element in field 0.  This is what lets a schema derived
   from the key/data/elt TYPES attach to the right slots, so the walker
   can label the user data below them instead of numbering it.  Payload
   fields that are not user data (a queue's [length], a hashtable's
   [size]) carry no role. *)
val payload_roles : t -> (int * string) list list
