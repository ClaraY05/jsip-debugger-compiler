
module Wire : sig
  type t = {
      location: string
      ; function_type: string
      ; function_data: string
      ; argument_list: (string * string) list
  }
  [@@deriving sexp]

  val format_function_call :  Typedtree.expression -> Typedtree.expression -> (Asttypes.arg_label * Typedtree.expression) list -> t
end

val inject_instrumentation : inject : Bool.t -> Typedtree.implementation  -> Typedtree.implementation 