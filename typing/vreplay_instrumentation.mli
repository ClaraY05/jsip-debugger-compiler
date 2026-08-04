(* -visual-replay's typed-tree pass: rewrites the calls and bindings that
   observe a tracked data structure so each one dumps an event at run
   time.  Everything else -- the wire record, the emit primitive, the
   catalogue tables -- is internal to the implementation; see the header
   of vreplay_instrumentation.ml, and vreplay/sexp.mli for the format. *)

val inject_instrumentation :
  inject:bool -> Typedtree.implementation -> Typedtree.implementation
