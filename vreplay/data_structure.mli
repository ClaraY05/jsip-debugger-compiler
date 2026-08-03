(* The catalogue of data structures visual replay knows how to walk.
   typing/vreplay_instrumentation.ml maps declaring units to these names
   in [ds_table]; extend both together when adding a data structure. *)

type t =
  (* stdlib *)
  | Map
  | Set
  | Queue
  | Hashtbl
  | Stack
  | Dynarray
  (* Base and Core.  One entry per REPRESENTATION, not per module:
     [Core.Map.t] is an alias of [Base.Map.t], and [Map.Poly], [Int.Map]
     and every [Make] instance are that same type, so one entry covers
     them all.  [Core.Linked_queue] is [Stdlib.Queue.t] and so belongs
     to [Queue], not here. *)
  | Core_map
  | Core_set
  | Core_hashtbl
  | Core_hash_set
  | Core_queue
  | Core_stack
  | Core_deque
  | Core_fdeque
  | Core_doubly_linked
  (* [User] is not a container: it is any type the user's own program
     declared, whose shape comes from the schema the instrumentation
     derived rather than from a hand-written layout here. *)
  | User

val to_string : t -> string

(* The catalogue name the instrumentation resolved at the call site
   (e.g. "Core_map") -> the catalogue entry.  The instrumentation may
   name entries this catalogue does not have yet; those events no-op at
   runtime. *)
val of_name : string -> t option

(* One accepted block shape within a layer.  [tag] is the block's tag,
   [None] for a layer whose blocks are records or tuples (any tag will
   do); a constructor's shape names its tag, which is its index among
   the type's NON-CONSTANT constructors in declaration order.

   Bit i of a mask covers field i of the block. *)
type shape =
  { tag : int option
  ; labels : string list
  ; interior : int
  ; payload : int
  }

(* An array layer's elements are either one layer deeper into the
   structure's own skeleton ([Interior] -- a hash table's buckets) or
   user data ([Payload] -- a queue's elements). *)
type elements =
  | Interior
  | Payload

(* Which slots of a buffer array are live, for a structure that keeps
   its elements in a preallocated array and its bounds in the parent
   record ([Base.Queue] and friends).  Every field named here is a field
   of the PARENT, read when the walk steps from it into the array; a
   field not holding an immediate voids the window (the whole array is
   walked then, which is what happens without one).

   Element k of the window is at [(start + start_offset + k) land mask],
   or [mod] the array's own size when there is no [mask] field, and is
   labelled with its logical position k -- so a wrapped buffer still
   reads in queue order.  [newest_first] walks the window backwards,
   which is how a stack shows its top first. *)
type window =
  { start : int option (* parent field holding the first live index *)
  ; start_offset : int (* added to [start] (a deque's front_index + 1) *)
  ; length : int option (* parent field holding the live element count *)
  ; mask : int option (* parent field holding the ring mask *)
  ; newest_first : bool
  }

(* Whether values of this DS never change after creation.  Immutable
   structures' dumped blocks are remembered (weakly) by the runtime so
   later events stop at them with [Id] references and dump only what is
   new; mutable ones are re-walked in full at every event. *)
val is_immutable : t -> bool

(* One layer of a DS's internal representation.  The walker tells a
   structure's own skeleton apart from the user data it holds by the
   EDGE it reached a block through, never by the block's shape:

   - [Fixed] describes an internal node of one exact size, whatever its
     tag.  [labels] name its fields; the [interior] bitmask marks fields
     that point one layer deeper into the structure's own skeleton; the
     [payload] bitmask marks fields holding user data.  Unmarked fields
     are bookkeeping and never reach the wire.
   - [Cases] describes a layer whose blocks come in several shapes and
     picks the one matching the block's tag and size -- a [Base] tree's
     [Leaf] and [Node], say.  Listing shapes that differ between library
     versions ([Base.Set]'s AVL [Node] and its weight-balanced
     successor) is how one layout serves both.
   - [Array_elements] is a variable-size block (an array); its fields
     get numeric labels, and [window] restricts them to the live slots.

   A block matching no shape of its layer is demoted to payload
   treatment rather than truncated or mislabelled.  Blocks reached
   through a payload edge -- and everything below them -- are user data:
   every field is kept, labels are numeric, and the DS masks never
   apply.  That is what keeps a user tuple from being truncated or
   mislabeled as a DS node, whatever its arity. *)
type layer =
  | Fixed of
      { labels : string list
      ; interior : int
      ; payload : int
      }
  | Cases of shape list
  | Array_elements of
      { elements : elements
      ; window : window option
      }

(* The layers of one DS, root first, in the order interior edges meet
   them.  Once the walk has stepped past the last layer, the last layer
   repeats (an interior chain -- Map's l/r spine, a bucket list's next
   -- keeps its own layer forever).  Empty only for [User], which has
   no skeleton of its own to describe. *)
val layout : t -> layer list

(* Which payload field of each layer carries which role of the event's
   [ty] -- (field LABEL, role name), one list per layer of [layout].
   A map's node holds its key in [v] and its data in [d]; a queue cell
   holds its element in field "0".  This is what lets a schema derived
   from the key/data/elt TYPES attach to the right slots, so the walker
   can label the user data below them instead of numbering it.  Payload
   fields that are not user data (a queue's [length], a hashtable's
   [size]) carry no role.

   Labels rather than field positions, because a layer's shapes need not
   agree on where a role sits: a Base map keeps its key in field 1 of a
   [Node] and field 0 of a [Leaf], and both call it [v].  The reserved
   label ["*"] is how an [Array_elements] layer names the role every one
   of its elements carries. *)
val payload_roles : t -> (string * string) list list
