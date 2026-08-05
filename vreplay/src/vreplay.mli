(* Visual-replay runtime support (linked into the instrumented program).
   The catalogue lives in data_structure.mli; the wire schema -- and its
   full prose spec, deltas and sharing rules included -- in sexp.mli.
   The types are re-exported here (same types, not copies) so [Vreplay]
   presents the whole contract. *)

type block = Sexp.block =
  | Int of int
  | Float of float
  | String of string
  | Int32 of int32
  | Int64 of int64
  | Nativeint of nativeint
  | Float_array of float list
  | Address of nativeint
  | Id of int
  | Child

type node = Sexp.node = {
  id : int;
  virtual_address : nativeint;
  block : (string * block) list;
  children : node list;
}

(* what one event passes to the other program *)
type t = Sexp.snapshot = {
  ds_type : Data_structure.t;
  root_node : node;
}

(* aliases of [Sexp.to_sexp] / [Sexp.from_sexp] *)
val to_sexp : t -> Sexp.t
val from_sexp : Sexp.t -> t

(* The injected entry point: assigns [root] a stable id (held weakly),
   has the C walker build its [node] tree, and emits one event line
   through [caml_wire_emit].  No-ops when [ds] is not a known catalogue
   name or [root] is immediate.  Dumps are DELTAS -- an immutable block
   is dumped at most once, a re-observation collapses to a revisit
   stub; sexp.mli has the rules.

   [name] is the identifier the root was observed under ("" = none;
   the registry keeps the latest non-empty name).  [binder] and [scope]
   say WHICH binding that name is and what every tracked name resolves
   to at this program point ([Sexp.sexp_of_scope]); [ty] is the root's
   printed static type plus role-labelled parameters.  One call can
   inject several [snapshot]s -- one per root, all inside its single
   {} frame -- sharing loc/fn/args and differing in root. *)
val snapshot :
  loc:string * int * int * int -> fn:string * string -> ds:string
  -> args:(string * string * string) list -> name:string
  -> binder:string -> scope:(string * string) list
  -> ty:string * (string * string) list
  -> schema:(string list * int list * int) list * (string * int) list
  -> 'a -> unit
(* [schema] lets the walker label the user data [root] can reach: a
   table of block shapes -- (labels, per-field entry, kind: 0 fixed /
   1 array; -1 unknown; a self-reference closes a recursive type) --
   plus the entry each of [ty]'s roles resolves to.
   [Data_structure.payload_roles] says which field carries which role. *)
