open Parsetree 

type t = unit

let print_node = ()

let unit = {ppat_desc=}

let print_then_run exp = 
  Parsetree.Pexp_let (Asttypes.rec_flag.Nonrecursive, 
  [({ppat_desc=idk; 
  ppat_loc=exp.pexp_loc; 
  ppat_loc_stack=exp.ppat_loc_stack; ppat_attributes=pexp.pexp_attributes}, print_node)], exp.pexp_desc)

let inject_expression exp={pexp_desc; pexp_loc; pexp_loc_stack; pexp_attributes} =
  match pexp_desc with 
  | Pexp_apply (exp, args) -> {print_then_run exp; pexp_loc; pexp_loc_stac; pexp_attributes}
  | _ -> {pexp_desc; pexp_loc; pexp_loc_stack; pexp_attributes} 


let inject_mapper = { Ast_mapper.default_mapper with 
  Ast_mapper.expr = inject_expression}

let inject_instrumentation ast = inject_mapper.Ast_mapper.structure inject_mapper ast 