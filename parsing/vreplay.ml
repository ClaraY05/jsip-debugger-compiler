(** iterate through expression and args from a pexp_apply and format for printing *)
let format_function_call (exp : Parsetree.expression) (func:Parsetree.expression) args =
 let arg_strings =
   let format_arg (arg_label,arg) =
     let label_string = match arg_label with
     | Asttypes.Nolabel  -> "NO_LABEL NONE"
     | Asttypes.Labelled label -> Format.asprintf "LABELLED %s" label
     | Asttypes.Optional label -> Format.asprintf "OPTIONAL %s" label
     in
     Format.asprintf "LABEL:[%s],ARGUMENT:[%s]" label_string (Pprintast.string_of_expression arg)
   in
   let rec format_args acc arg_list = match arg_list with
     | [] -> acc
     | first_arg::rest_of_args -> format_args ((format_arg(first_arg))::acc) rest_of_args
   in
   let rec reverse acc list = match list with
     | [] -> acc
     | first::rest -> reverse (first::acc) rest
   in
   String.concat ";" (reverse [] (format_args [] args))
 in
 let exp_string = match func.pexp_desc with
   | Pexp_ident (lid) -> Format.asprintf "function_name:[%a]" Pprintast.longident lid.txt
   | _ -> Format.asprintf "unnamed:[%a]" Pprintast.expression func
 in
 let location_string = Format.asprintf "%a" Location.print_loc exp.pexp_loc in 
 Format.asprintf "{FUNCTION(%s) ARGUMENTS(%s) LOCATION(%s)\n" exp_string arg_strings location_string

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
let print_expression exp func args =
  print_string_node (format_function_call exp func args)


(* wrapper to run the given function after printing it. exp should be a Pexp_apply to type check. *)
let print_then_run_node (exp : Parsetree.expression) (func : Parsetree.expression) args = 
  (* First print out the function information *)
  Parsetree.Pexp_let (Asttypes.Nonrecursive, 
  [{
    pvb_pat=
      { ppat_desc=Parsetree.Ppat_construct (Location.mknoloc (Longident.Lident "()"), None)
      ; ppat_loc=exp.pexp_loc
      ; ppat_loc_stack=exp.pexp_loc_stack
      ; ppat_attributes=exp.pexp_attributes
      }
  ; pvb_expr= print_expression exp func args
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
   (* Print out the ending bracket *)
  , Ast_helper.Exp.mk (Parsetree.Pexp_let (Asttypes.Nonrecursive, 
  [{
    pvb_pat=
      { ppat_desc=Parsetree.Ppat_construct (Location.mknoloc (Longident.Lident "()"), None)
      ; ppat_loc=exp.pexp_loc
      ; ppat_loc_stack=exp.pexp_loc_stack
      ; ppat_attributes=exp.pexp_attributes
      }
  ; pvb_expr= print_string_node "}"
  ; pvb_constraint=None
  ; pvb_attributes=exp.pexp_attributes
  ; pvb_loc=exp.pexp_loc
  }]
   (* "return" the result *)
  , Ast_helper.Exp.mk (Parsetree.Pexp_ident (Location.mknoloc (Longident.Lident "res"))))))))


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
let inject_instrumentation ~inject ast = if inject then inject_mapper.Ast_mapper.structure inject_mapper ast else ast


(* - we need to separate out function body pexp_applies
- At actual pexp_applies, we need to calculate some notion of depth
- then add this calculated depth to the function body depth. 



- it's near impossible to reach back into the function body at the actual pexp apply time (unless we store all functions which seems unnecessary/impractical)
- let's instead just put parens around function calls and then parse them interface-side *)
