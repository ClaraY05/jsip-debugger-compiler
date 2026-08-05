(* Object identity: the weak registry of tracked structures and the
   member store of already-dumped blocks.  Identity is physical and
   every reference weak -- tracking never keeps a value alive. *)

(* Opaque stable wire ids, one counter for everything on the wire.  The
   C walker assigns interior-cell ids itself, sequentially from
   [next_int]; [advance] consumes them so no id is issued twice. *)
module Id : sig
  type t
  val to_int : t -> int
  val next_int : unit -> int
  val advance : int -> unit
end

(* Track a root under a source name (latest non-empty name wins; "" is
   anonymous).  Returns its stable id and whether this is its FIRST
   dump -- false for a re-observation or a block already on the wire. *)
val register : Obj.t -> name:string -> Id.t * bool

(* live (value, id, name) triples in insertion order; compacts the
   registry, retiring collected ids *)
val live_known : unit -> (Obj.t * int * string) array

(* The member table for one event: every live remembered member plus
   every live registry root except [root] -- included only under
   [include_root], which is what collapses an immutable re-observation
   to a revisit stub.  Compacts the member store. *)
val live_members :
  known:(Obj.t * int * string) array -> root:Obj.t -> include_root:bool
  -> root_id:int -> (Obj.t * int) array

(* remember a first walk's new cells, re-reached through their discovery
   edges (parent cell index, raw field index), ids from [first_id] *)
val absorb_members :
  root:Obj.t -> paths:(int * int) array -> first_id:int -> unit
