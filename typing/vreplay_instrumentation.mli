(* -visual-replay's typed-tree pass: rewrites the calls and bindings that
   observe a tracked data structure so each one dumps an event at run
   time.  Everything else -- the wire record, the emit primitive, the
   catalogue tables -- is internal to the implementation; see the header
   of vreplay_instrumentation.ml, and vreplay/src/sexp.mli for the format. *)

val inject_instrumentation :
  inject:bool -> Typedtree.implementation -> Typedtree.implementation

(* every catalogue name the instrumentation can emit as an event's
   [ds]; an unknown name silently no-ops at run time, which is what
   vreplay/tests/check_catalogue.ml exists to catch *)
val catalogue_names : string list
