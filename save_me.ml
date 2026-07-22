(** iterate through expression and args from a pexp_apply and format for printing *)
let format_function_call (func:Parsetree.expression) args =
 let arg_strings =
   let format_arg (arg_label,arg) =
     let label_string = match arg_label with
     | Asttypes.Nolabel  -> "NO_LABEL"
     | Asttypes.Labelled _ -> "LABELLED"
     | Asttypes.Optional _ -> "OPTIONAL"
     in
     Format.asprintf "(LABEL:[%s],ARGUMENT:[%s])" label_string (Pprintast.string_of_expression arg)
   in
   let rec format_args acc arg_list = match arg_list with
     | [] -> acc
     | first_arg::rest_of_args -> format_args ((format_arg(first_arg))::acc) rest_of_args
   in
   let rec reverse acc list = match list with
     | [] -> acc
     | first::rest -> reverse (first::acc) rest
   in
   String.concat "," (reverse [] (format_args [] args))
 in
 let exp_string = match func.pexp_desc with
   | Pexp_ident (lid) -> Format.asprintf "function_name:[%a]" Pprintast.longident lid.txt
   | _ -> Format.asprintf "unnamed:[%a]" Pprintast.expression func
 in
 Format.asprintf "FUNCTION(%s) ARGUMENTS(%s)\n" exp_string arg_strings

(* print a generic string *)
let print_string_node input =
 let module_longident = Longident.Lident "Printf" in
 let print_longident = Longident.Ldot (Location.mknoloc module_longident, Location.mknoloc "printf") in
 let print_function = Ast_helper.Exp.ident (Location.mknoloc print_longident) in
 let print_arg = Ast_helper.Exp.constant {
   pconst_desc = (Pconst_string (input, Location.none, None));
   pconst_loc = Location.none} in
 Ast_helper.Exp.apply print_function [ (Nolabel, print_arg) ]
;;

(* wrapper to print a function call *)
let print_expression func args =
  print_string_node (format_function_call func args)


(* wrapper to run the given function after printing it. exp should be a Pexp_apply to type check. *)
let print_then_run_node (exp : Parsetree.expression) (func : Parsetree.expression) args = 
  Parsetree.Pexp_let (Asttypes.Nonrecursive, 
  [{
    pvb_pat=
      { ppat_desc=Parsetree.Ppat_construct (Location.mknoloc (Longident.Lident "()"), None)
      ; ppat_loc=exp.pexp_loc
      ; ppat_loc_stack=exp.pexp_loc_stack
      ; ppat_attributes=exp.pexp_attributes
      }
  ; pvb_expr= print_expression func args
  ; pvb_constraint=None
  ; pvb_attributes=exp.pexp_attributes
  ; pvb_loc=exp.pexp_loc
  }]
   (* This is a pattern for let () = ... *)
  , exp)


  (* This is our special mapper that changes pexp_applies *)
let inject_mapper = 
  let super = Ast_mapper.default_mapper in 

  (* this function injects a print before every function application *)
  let inject_expression self (exp : Parsetree.expression) = 
    let recurse_down : Parsetree.expression = super.expr self exp in 
    
    match recurse_down.pexp_desc with 
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
let inject_instrumentation ~inject ast = if inject then inject_mapper.Ast_mapper.structure inject_mapper ast else ast



(* TODO: make it recursive, ignore function bodies *)