(* let print_node input =
  let module_longident = Longident.Lident "Printf" in
  let print_longident = Longident.Ldot (Location.mknoloc module_longident, Location.mknoloc "printf") in 
  let print_function = Ast_helper.Exp.ident (Location.mknoloc print_longident) in
  let print_arg = Ast_helper.Exp.constant {
    pconst_desc = (Pconst_string (input, Location.none, None));
    pconst_loc = Location.none} in
  Ast_helper.Exp.apply print_function [ (Nolabel, print_arg) ] *)


let print_then_run_node (exp : Parsetree.expression) = 
  Parsetree.Pexp_let (Asttypes.Nonrecursive, 
  [{pvb_pat={
    ppat_desc=Parsetree.Ppat_construct (Location.mknoloc (Longident.Lident "()"), None);
    ppat_loc=exp.pexp_loc;
    ppat_loc_stack=exp.pexp_loc_stack;
    ppat_attributes=exp.pexp_attributes;};
  pvb_expr=exp; (* change this to print_node when it gets implemented!! *)
  pvb_constraint=None;
  pvb_attributes=[]; 
  pvb_loc=(exp.pexp_loc)}]
   (* This is a pattern for let () = ... *)
    
  , exp)
(* i need to fix pvb_attributes, shouldn't be a [] i think. !! *)


(* This function injects a print node onto every Pexp_apply *)
let inject_expression _mapper (exp : Parsetree.expression) =
  match exp.pexp_desc with 
  | Pexp_apply (_func, _args) -> 
    ({pexp_desc=print_then_run_node exp;
     pexp_loc=exp.pexp_loc;
   pexp_loc_stack=[exp.pexp_loc]; 
   pexp_attributes=exp.pexp_attributes} : Parsetree.expression)
  | _ -> exp

  (* This is our special mapper that changes pexp_applies *)
let inject_mapper = { Ast_mapper.default_mapper with 
  Ast_mapper.expr = inject_expression}

  (* exposed for compile_commmon *)
let inject_instrumentation ~inject ast = if inject then inject_mapper.Ast_mapper.structure inject_mapper ast else ast