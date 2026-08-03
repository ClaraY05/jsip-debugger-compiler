(* Visual replay's serialization module: a minimal s-expression AST (the
   compiler build has no sexplib and must not grow an opam dependency),
   plus the wire schema and its converters.  vreplay.ml re-exports the
   schema, so [Vreplay.t] and [Sexp.snapshot] are the same type. *)

type t =
  | Atom of string
  | List of t list

(* Renders on one line.  Atoms are quoted/escaped the way sexplib quotes
   printable ASCII (specials and non-printables in "..." with \-escapes),
   so the output parses with either [of_string] or sexplib. *)
val to_string : t -> string

(* Parses exactly one sexp; the inverse of [to_string].  Raises [Failure]
   on malformed or trailing input. *)
val of_string : string -> t

(* ---- the wire schema ----
   Built in C by [caml_wire_traverse] (runtime/snapshot.c); constructor
   and field ORDER are part of that contract -- change both sides or
   neither. *)

(* A meaningful non-child field of a node, decoded per the representation
   tables in the OCaml manual, "Interfacing C with OCaml", section "The
   value type" / "Representation of OCaml data types".  Atomic types:

     int, char, bool, unit,
     constant constructors   -> Int         (unboxed integer values; the
                                             runtime cannot tell these
                                             apart -- a char arrives as
                                             its ASCII code)
     float                   -> Float       (Double_tag block)
     string, bytes           -> String      (String_tag block)
     int32                   -> Int32       (Custom_tag block, ops "_i")
     int64                   -> Int64       (Custom_tag block, ops "_j")
     nativeint               -> Nativeint   (Custom_tag block, ops "_n")
     float array, floatarray,
     all-float records       -> Float_array (Double_array_tag block)

   Tuples, records and non-constant constructors are zero-tagged
   (scannable) blocks: within the data structure they are walked and
   appear as child [node]s -- unless the dump already defines them, in
   which case they appear as [Id n]: a reference to the unique node
   carrying [(id n)], dumped by an earlier event (a tracked root, a
   remembered member of an immutable structure) or earlier in this same
   walk (sharing, a cycle).  [Address] carries only a block we do not
   decode (Abstract_tag, an unknown Custom_tag). *)
type block =
  | Int of int
  | Float of float
  | String of string
  | Int32 of int32
  | Int64 of int64
  | Nativeint of nativeint
  | Float_array of float list
  | Address of nativeint
  | Id of int

type node = {
  id : int;                         (* wire id, unique across the dump *)
  virtual_address : nativeint;      (* the block's address at snapshot time *)
  block : (string * block) list;    (* labeled meaningful data fields *)
  children : node list;             (* masked fields that are DS-internal *)
}

(* Both lists preserve field order, and [block] holds every masked
   non-child field -- so a masked field absent from [block] was a child,
   and the k-th such absence is [children]'s k-th node.  That is how a
   reader recovers which side (l/r) a child hung off.  ([Id] fields sit
   in [block] like any other leaf, so the rule is unaffected by
   sharing.)

   Dumps are DELTAS.  For immutable structures (Map/Set) a block is
   dumped -- given a node with a fresh [(id n)] -- at most once in the
   whole dump; every later occurrence is an [Id n] reference, and a
   re-observed structure's whole event collapses to a REVISIT STUB: its
   root's id again, the current address, empty [block] and [children].
   Mutable structures (Queue/Hashtbl) re-walk in full at every event:
   the root keeps its registry id across these re-dumps while interior
   cells take fresh ids each time.  A reader reconstructs any event by
   resolving [Id n] against the node that defined [(id n)] earlier in
   the dump. *)

(* What one event passes to the other program: the DS type stated once,
   plus the walked shape. *)
type snapshot = {
  ds_type : Data_structure.t;
  root_node : node;
}

(* [to_sexp]/[from_sexp] follow [@@deriving sexp] conventions for the
   definitions above, e.g.

     ((ds_type Map)
      (root_node ((id 3) (virtual_address 0x7f...)
                  (block ((l (Int 0)) (v (Int 1)) (d (Float 3.14))))
                  (children ()))))

   (one line on the wire), so the interface repo can mirror the types with
   ppx_sexp_conv and derive its reader.  [from_sexp] is the exact inverse
   of [to_sexp] and raises [Failure] on any other shape. *)
val to_sexp : snapshot -> t
val from_sexp : t -> snapshot

(* The live weak registry at event time as (id, current address, name)
   triples -- the event wrapper carries it beside the snapshot, and it is
   the single source of CURRENT memory locations for tracked structures
   (any [Id i] also resolves against the node that carried [(id i)]
   earlier in the dump).  Ids
   are stable across events; addresses are captured by the same C walk as
   the nodes.  The name is the latest non-empty identifier the structure
   was observed under (a later event may rename it); a named entry
   renders as [(1 0x7f2ce89e q)], an anonymous one ([""]) keeps the
   two-atom [(1 0x7f2ce89e)] shape.  Entries appear when a structure is
   first tracked and disappear once the GC has collected it. *)
val sexp_of_registry : (int * nativeint * string) array -> t

(* The static type of the walked root, as the instrumentation printed it
   off the typedtree:

     (ty ((printed "int M.t") (params ((key string) (data int)))))

   [printed] is the root's type as inferred at the call site (aliases
   kept).  [params] labels the types a reader displays without parsing
   OCaml syntax -- [key]/[data] for maps and hashtables, [elt] for sets
   and queues -- and omits any role the instrumentation could not
   resolve (e.g. the structure's module is a functor parameter). *)
val sexp_of_ty : string * (string * string) list -> t

(* The remaining event-wrapper fields, rendered in the shapes
   [@@deriving sexp] gives the interface repo's own types so its reader
   is derived, not hand-written:

     loc   ((file_path t.ml) (line_number 4) (char_range (10 23)))
     fn    (Function_name M.add)  or  (Unnamed "fun x -> ...")
     args  ((No_label (expression (Unnamed m)))
            (Labelled (label init) (expression (Unnamed 0))))

   The fn/argument constructor names are computed at compile time by the
   instrumentation (an argument's label is empty and unused for
   No_label); the source text of an argument the application was
   abstracted over is OMITTED. *)
val sexp_of_loc : string * int * int * int -> t
val sexp_of_fn : string * string -> t
val sexp_of_args : (string * string * string) list -> t
