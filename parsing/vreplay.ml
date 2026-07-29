(* open! Parsetree *)

(*module Wire = struct
  type t = {
      location: string
      ; function_type: string
      ; function_data: string
      ; argument_list: (string * string) list
  }
  [@@deriving sexp]

  let format_function_call (exp : Parsetree.expression) (func:Parsetree.expression) args = 
    let location = Format.asprintf "%a" Location.print_loc exp.pexp_loc in
    let function_type, function_data = match func.pexp_desc with
    | Pexp_ident (lid) -> "Function_name", Format.asprintf "%a" Pprintast.longident lid.txt
    | _ -> "Unnamed", Format.asprintf "%a" Pprintast.expression func
    in
    let argument_list =
      let format_arg (arg_label,arg) = match arg_label with
        | Asttypes.Nolabel  -> "NO_LABEL", ""
        | Asttypes.Labelled label -> "LABELLED", Format.asprintf "%s" label
        | Asttypes.Optional label -> "OPTIONAL", Format.asprintf "%s" label
      in
      let rec format_args acc arg_list = match arg_list with
        | [] -> acc
        | first_arg::rest_of_args -> format_args ((format_arg(first_arg))::acc) rest_of_args
      in
      let rec reverse acc list = match list with
        | [] -> acc
        | first::rest -> reverse (first::acc) rest
      in
      reverse [] (format_args [] args)
    in
    {location; function_type; function_data; argument_list}
  ;;
end*)

(* print a generic string *)
(*=let print_string_node input =
 let module_longident = Longident.Lident "Printf" in
 let print_longident = Longident.Ldot (Location.mknoloc module_longident, Location.mknoloc "printf") in
 let print_function = Ast_helper.Exp.ident (Location.mknoloc print_longident) in
 let print_arg = Ast_helper.Exp.constant {
   pconst_desc = (Pconst_string (input, Location.none, None));
   pconst_loc = Location.none} in
 Ast_helper.Exp.apply print_function [ (Nolabel, print_arg) ]
;;*)

(* the [external] we splice into each instrumented structure *)
let wire_external =
  let ty_constr name =
    Ast_helper.Typ.constr (Location.mknoloc (Longident.Lident name)) []
  in
  let emit_type =
    Ast_helper.Typ.arrow Nolabel (ty_constr "string") (ty_constr "unit")
  in
  Ast_helper.Str.primitive
    (Ast_helper.Prim.mk_decl
       ~prim:[ "caml_wire_emit" ]
       (Location.mknoloc "__wire_emit")
       emit_type)
;;

(* call a c function *)
(* call a c function *)
let call_c_node input =
 let callc_function =
   Ast_helper.Exp.ident (Location.mknoloc (Longident.Lident "__wire_emit")) in
 let callc_arg = Ast_helper.Exp.constant {
   pconst_desc = (Pconst_string (input, Location.none, None));
   pconst_loc = Location.none} in
 Ast_helper.Exp.apply callc_function [ (Nolabel, callc_arg) ]
;;

(* wrapper to run the given function after printing it. exp should be a Pexp_apply to type check. *)
let print_then_run_node (exp : Parsetree.expression) (_func : Parsetree.expression) _args = 
  (* First print out the function information *)
  Parsetree.Pexp_let (Asttypes.Nonrecursive, 
  [{
    pvb_pat=
      { ppat_desc=Parsetree.Ppat_construct (Location.mknoloc (Longident.Lident "()"), None)
      ; ppat_loc=exp.pexp_loc
      ; ppat_loc_stack=exp.pexp_loc_stack
      ; ppat_attributes=exp.pexp_attributes
      }
  ; pvb_expr= call_c_node "meow\n"
  ; pvb_constraint=None
  ; pvb_attributes=exp.pexp_attributes
  ; pvb_loc=exp.pexp_loc
  }]
   (* Then evaluate the function and bind to res *)
  , Ast_helper.Exp.mk (Parsetree.Pexp_let (Asttypes.Nonrecursive, 
  [{
    pvb_pat=
      { ppat_desc=Parsetree.Ppat_var (Location.mknoloc "res")
      ; ppat_loc=exp.pexp_loc
      ; ppat_loc_stack=exp.pexp_loc_stack
      ; ppat_attributes=exp.pexp_attributes
      }
  ; pvb_expr= exp
  ; pvb_constraint=None
  ; pvb_attributes=exp.pexp_attributes
  ; pvb_loc=exp.pexp_loc
  }]
   (* "return" the result *)
  , Ast_helper.Exp.mk (Parsetree.Pexp_ident (Location.mknoloc (Longident.Lident "res"))))))


  (* This is our special mapper that changes pexp_applies *)
let inject_mapper = 
  let super = Ast_mapper.default_mapper in 

  (* this function injects a print before every function application *)
  let inject_expression self (exp : Parsetree.expression) = 
    let recurse_down : Parsetree.expression = super.expr self exp in 
    match exp.pexp_desc with 
    | Pexp_apply (func, args) ->
      ({  pexp_desc = print_then_run_node recurse_down func args
        ; pexp_loc = exp.pexp_loc
        ; pexp_loc_stack = exp.pexp_loc_stack
        ; pexp_attributes = exp.pexp_attributes
      } : Parsetree.expression)
    | _ -> recurse_down
  in
  { 
    Ast_mapper.default_mapper with 
    Ast_mapper.expr = inject_expression
  }

  (* exposed for compile_commmon *)
let inject_instrumentation ~inject ast = if inject
  then wire_external :: inject_mapper.Ast_mapper.structure inject_mapper ast
  else ast


(* - we need to separate out function body pexp_applies
- At actual pexp_applies, we need to calculate some notion of depth
- then add this calculated depth to the function body depth. 



- it's near impossible to reach back into the function body at the actual pexp apply time (unless we store all functions which seems unnecessary/impractical)
- let's instead just put parens around function calls and then parse them interface-side *)
