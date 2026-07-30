(* Visual-replay runtime support (linked into the instrumented program).

   The catalogue of walkable data structures -- the [Data_structure.t]
   variant and its layouts (labels + mask) -- lives in data_structure.mli.
   The wire schema and all sexp conversion live in sexp.mli; the types are
   re-exported here (same types, not copies) so [Vreplay] presents the
   whole contract.  See sexp.mli for the representation mapping and the
   wire examples. *)

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

type node = Sexp.node = {
  virtual_address : nativeint;
  block : (string * block) list;
  children : node list;
}

(* What one event passes to the other program: the DS type stated once,
   plus the walked shape. *)
type t = Sexp.snapshot = {
  ds_type : Data_structure.t;
  root_node : node;
}

(* Aliases of [Sexp.to_sexp] / [Sexp.from_sexp]. *)
val to_sexp : t -> Sexp.t
val from_sexp : Sexp.t -> t

(* [snapshot ~loc ~fn ~ds ~args root] assigns [root] a stable id (holding
   it weakly), has the C walker build the [node] tree for it, and emits
   one line through [caml_wire_emit]:

     (event (id 2) (loc "File ...") (fn Map.add)
       (args ((NO_LABEL "\"a\"") (NO_LABEL 1) (NO_LABEL m)))
       (registry ...) (snapshot <to_sexp>))

   [args] is the call's arguments as (label-kind, source-text) pairs,
   computed at compile time (see Sexp.sexp_of_args).  No-ops when [ds]
   is not a known data structure or [root] is immediate. *)
val snapshot :
  loc:string -> fn:string -> ds:string -> args:(string * string) list
  -> 'a -> unit
