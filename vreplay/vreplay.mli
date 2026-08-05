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
  | Child

type node = Sexp.node = {
  id : int;
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

(* [snapshot ~loc ~fn ~ds ~args ~name ~ty root] assigns [root] a stable
   id (holding it weakly), has the C walker build the [node] tree for
   it, and emits one line through [caml_wire_emit]:

     (event (id 2)
       (loc ((file_path t.ml) (line_number 4) (char_range (10 23))))
       (fn (Function_name M.add))
       (args ((No_label (expression (Unnamed "\"a\"")))
              (No_label (expression (Unnamed m)))))
       (registry ...) (ty ...) (snapshot <to_sexp>))

   [loc], [fn] and [args] are computed at compile time and rendered in
   the interface repo's own type shapes (see Sexp.sexp_of_loc/fn/args).
   No-ops when [ds] is not a known data structure or [root] is
   immediate.

   Dumps are DELTAS (see sexp.mli): every node carries a wire id,
   unique across the dump, and for immutable structures (Map/Set) a
   block is dumped at most once, ever -- the runtime remembers dumped
   blocks weakly, walks stop at any of them with an [Id] reference, and
   a re-observed structure emits just a revisit stub.  So an event for
   [Map.add] carries only the rebuilt path; the subtrees it shares with
   earlier versions stay [Id]s, which is how a reader detects the
   sharing.  Mutable structures (Queue/Hashtbl) re-walk in full at
   every event, their cells taking fresh ids each time.  One accepted
   consequence: a payload block mutated AFTER its structure was dumped
   keeps showing its dump-time contents (it is never re-walked).

   [name] is the source identifier the root was observed under -- the
   [let] binder for a bound result, a mutated container argument's own
   identifier -- or "" when there is none (nested calls, wildcard
   patterns, results of helpers).  The registry renders a named entry as
   [(id address name)] and an anonymous one as [(id address)]; the
   LATEST non-empty name a structure was observed under wins, so an
   entry can rename between events as the program passes the value
   around.

   [binder] and [scope] say which BINDING that name is, and what the
   unit's tracked names mean at this program point -- see
   [Sexp.sexp_of_scope].  The name alone cannot tell [let m = M.add "a" 1
   m]'s two versions apart, since both stay alive and both are called
   [m]; the binder can, so a reader knows which one the program can still
   reach.  [binder] is "" for a root observed under no name.

   [ty] is the root's static type as the instrumentation printed it off
   the typedtree -- the full type plus the role-labelled parameters a
   reader displays without parsing OCaml syntax; see [Sexp.sexp_of_ty].
   It describes THIS record's root (each record carries its own), and a
   structure's latest record carries its current display type.

   One CALL can carry several observations: the instrumentation injects
   one [snapshot] -- one record -- per root (each mutated container
   argument, then a structure result), all inside the call's single
   {} frame.  A reader must accept several records between one pair of
   markers; they share loc/fn/args and differ in root. *)
val snapshot :
  loc:string * int * int * int -> fn:string * string -> ds:string
  -> args:(string * string * string) list -> name:string
  -> binder:string -> scope:(string * string) list
  -> ty:string * (string * string) list
  -> schema:(string list * int list * int) list * (string * int) list
  -> 'a -> unit
(* [schema] describes the USER DATA this root can reach, so the walker
   can label payload blocks instead of numbering their fields: a table
   of block shapes plus the entry each of [ty]'s roles resolves to.
   An entry is (labels, fields, kind) -- [labels] names fields
   positionally ("" = unnamed, fall back to the index), [fields] gives
   per field the entry describing what it points at (-1 = unknown),
   and [kind] is 0 for a fixed-size block (record, tuple, list cell) or
   1 for an array whose every slot takes the single entry in [fields].
   Entries may refer to themselves: that is how a list cell's tail and
   a recursive record close their loop.  [Data_structure.payload_roles]
   says which field of which layer each role attaches to. *)
