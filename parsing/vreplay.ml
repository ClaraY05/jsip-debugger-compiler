
type t = unit


(** making a print statement for a given file *)
let print_function input =
  let module_longident = Longident.Lident "Printf" in
  let print_longident = Longident.Ldot (Location.mknoloc module_longident, Location.mknoloc "printf") in 
  let print_function = Exp.ident (Location.mknoloc print_longident) in
  let print_arg = Exp.constant {
    pconst_desc = (Pconst_string (input, Location.none, None));
    pconst_loc = Location.none} in
  Exp.apply print_function [ (Nolabel, print_arg) ]


let print_then_run exp = 
  Parsetree.Pexp_let (Asttypes.Nonrecursive, 


  [{pvb_pat=Parsetree.Ppat_construct (Longident.mknoloc (Longident.Lident "()"), None);
  pvb_expr=exp; (* change this to print_node!! *)
  pvb_constraint=None;
  pvb_attributes=[]; 
  pvb_loc=exp.pexp_loc}]
    
  (* [({ppat_desc=Parsetree.Ppat_construct (Longident.mknoloc (Longident.Lident "()"), None); 
  ppat_loc=exp.pexp_loc; 
  ppat_loc_stack=exp.ppat_loc_stack; ppat_attributes=pexp.pexp_attributes}, exp)] *)
  
  , exp)
(* change the exp above to print_node *)


let inject_expression exp={pexp_desc; pexp_loc; pexp_loc_stack; pexp_attributes} =
  match pexp_desc with 
  | Pexp_apply (exp, args) -> {pexp_desc=print_then_run exp; pexp_loc; pexp_loc_stac; pexp_attributes}
  | _ -> {pexp_desc; pexp_loc; pexp_loc_stack; pexp_attributes} 


let inject_mapper = { Ast_mapper.default_mapper with 
  Ast_mapper.expr = inject_expression}

let inject_instrumentation ast = inject_mapper.Ast_mapper.structure inject_mapper ast 