(* -visual-replay's typed-tree pass: rewrites the calls and bindings that
   observe a tracked data structure so each one dumps an event at run
   time.  Everything else -- the wire record, the emit primitive, the
   catalogue tables -- is internal to the implementation; see the header
   of vreplay_instrumentation.ml, and vreplay/src/sexp.mli for the format. *)

val inject_instrumentation :
  inject:bool -> Typedtree.implementation -> Typedtree.implementation

(* Every catalogue name the instrumentation can emit as an event's
   [ds].  vreplay/tests/check_catalogue.ml holds each to
   [Data_structure.of_name]: an unknown name silently no-ops at run
   time, which is exactly what the check exists to catch. *)
val catalogue_names : string list
