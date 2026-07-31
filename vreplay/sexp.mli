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
   appear as child [node]s; at a tracked boundary they appear as [Id] --
   the registry id of the tracked structure, which this event's registry
   maps to its current address (index by the int; the registry is the
   single source of memory locations).  [Address] carries only a block
   we do not decode (Abstract_tag, an unknown Custom_tag). *)
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
  virtual_address : nativeint;      (* the block's address at snapshot time *)
  block : (string * block) list;    (* labeled meaningful data fields *)
  children : node list;             (* masked fields that are DS-internal *)
}

(* Both lists preserve field order, and [block] holds every masked
   non-child field -- so a masked field absent from [block] was a child,
   and the k-th such absence is [children]'s k-th node.  That is how a
   reader recovers which side (l/r) a child hung off. *)

(* What one event passes to the other program: the DS type stated once,
   plus the walked shape. *)
type snapshot = {
  ds_type : Data_structure.t;
  root_node : node;
}

(* [to_sexp]/[from_sexp] follow [@@deriving sexp] conventions for the
   definitions above, e.g.

     ((ds_type Map)
      (root_node ((virtual_address 0x7f...)
                  (block ((l (Int 0)) (v (Int 1)) (d (Float 3.14))))
                  (children ()))))

   (one line on the wire), so the interface repo can mirror the types with
   ppx_sexp_conv and derive its reader.  [from_sexp] is the exact inverse
   of [to_sexp] and raises [Failure] on any other shape. *)
val to_sexp : snapshot -> t
val from_sexp : t -> snapshot

(* The live weak registry at event time as (id, current address, name)
   triples -- the event wrapper carries it beside the snapshot, and it is
   the single source of memory locations for tracked structures: an
   [Id i] inside the snapshot is resolved by indexing this registry.  Ids
   are stable across events; addresses are captured by the same C walk as
   the nodes.  The name is the latest non-empty identifier the structure
   was observed under (a later event may rename it); a named entry
   renders as [(1 0x7f2ce89e q)], an anonymous one ([""]) keeps the
   two-atom [(1 0x7f2ce89e)] shape.  Entries appear when a structure is
   first tracked and disappear once the GC has collected it. *)
val sexp_of_registry : (int * nativeint * string) array -> t

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
