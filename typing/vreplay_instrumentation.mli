module Wire : sig
  type t = {
      location: string
      ; function_type: string
      ; function_data: string
      ; argument_list: (string * string) list
  }
  [@@deriving sexp]

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
