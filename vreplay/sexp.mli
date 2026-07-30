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
   appear as child [node]s; at a tracked boundary they appear as
   [Address].  [Address] also carries any block we do not decode
   (Abstract_tag, an unknown Custom_tag). *)
type block =
  | Int of int
  | Float of float
  | String of string
  | Int32 of int32
  | Int64 of int64
  | Nativeint of nativeint
  | Float_array of float list
  | Address of nativeint

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
