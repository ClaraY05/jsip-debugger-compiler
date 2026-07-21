open Parsetree

type t = unit


(** making a print statement for a given file *)
(* let print_function input =
  let module_longident = Longident.Lident "Printf" in
  let print_longident = Longident.Ldot (Location.mknoloc module_longident, Location.mknoloc "printf") in 
  let print_function = Ast_helper.Exp.ident (Location.mknoloc print_longident) in
  let print_arg = Ast_helper.Exp.constant {
    pconst_desc = (Pconst_string (input, Location.none, None));
    pconst_loc = Location.none} in
  Ast_helper.Exp.apply print_function [ (Nolabel, print_arg) ] *)


let print_then_run (exp : Parsetree.expression) = 
  Parsetree.Pexp_let (Asttypes.Nonrecursive, 
  [{pvb_pat={
    ppat_desc=Parsetree.Ppat_construct (Location.mknoloc (Longident.Lident "()"), None);
    ppat_loc=exp.pexp_loc;
    ppat_loc_stack=exp.pexp_loc_stack;
    ppat_attributes=exp.pexp_attributes;};
  pvb_expr=exp; (* change this to print_node!! *)
  pvb_constraint=None;
  pvb_attributes=[]; 
  pvb_loc=(exp.pexp_loc)}]
    
  , exp)
(* fix attributes!! *)
let inject_expression _mapper (exp : Parsetree.expression) =
  match exp.pexp_desc with 
  | Pexp_apply (exp, _args) -> 
    ({pexp_desc=print_then_run exp;
     pexp_loc=exp.pexp_loc;
   pexp_loc_stack=[exp.pexp_loc]; 
   pexp_attributes=exp.pexp_attributes} : Parsetree.expression)
  | _ -> exp

let inject_mapper = { Ast_mapper.default_mapper with 
  Ast_mapper.expr = inject_expression}

let inject_instrumentation ast = inject_mapper.Ast_mapper.structure inject_mapper ast 