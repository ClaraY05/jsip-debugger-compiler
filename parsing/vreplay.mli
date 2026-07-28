(* open! Parsetree *)

module Wire : sig
  type t = {
      location: string
      ; function_type: string
      ; function_data: string
      ; argument_list: (string * string) list
  }
  [@@deriving sexp]

  val format_function_call :  Parsetree.expression -> Parsetree.expression -> (Asttypes.arg_label * Parsetree.expression) list -> t
end

val inject_instrumentation : inject : Bool.t -> Parsetree.structure  -> Parsetree.structure 