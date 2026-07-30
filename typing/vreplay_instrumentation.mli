module Wire : sig
  (* Field shapes mirror the interface repo's own types (its Location.t
     components and its Function_info.t / Argument.t constructor names);
     see Sexp.sexp_of_loc/fn/args in vreplay/sexp.mli for how each is
     rendered on the wire. *)
  type t = {
      location: string * int * int * int
      ; function_info: string * string
      ; argument_list: (string * string * string) list
  }

  (* the argument list is the one [Texp_apply] carries, so its second
     component is an [apply_arg] rather than a plain expression *)
  val format_function_call :
    Typedtree.expression
    -> Typedtree.expression
    -> (Asttypes.arg_label * Typedtree.apply_arg) list
    -> t
end

val inject_instrumentation :
  inject:bool -> Typedtree.implementation -> Typedtree.implementation
