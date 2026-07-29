module Wire = struct
  type t = {
      location: string
      ; function_type: string
      ; function_data: string
      ; argument_list: (string * string) list
  }
  [@@deriving sexp]

  let format_function_call (exp : Typedtree.expression) (func:Typedtree.expression) args = 
    let location = Format.asprintf "%a" Location.print_loc exp.exp_loc in
    let function_type, function_data = match func.exp_desc with
    | Texp_ident (_,lid,_) -> "Function_name", Format.asprintf "%a" Pprintast.longident lid.txt
    | _ -> "Unnamed", Format.asprintf "%a" Pprintast.expression (Untypeast.untype_expression func)
    in
    let argument_list =
      let format_arg (arg_label,_arg) = match arg_label with
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
end

(* the [external] we splice into each instrumented structure. [call_c_node]
   refers to it by this name, so the declaration and the call sites must agree. *)
let wire_emit_name = "__wire_emit"

let wire_external =
  let ty_constr name =
    Ast_helper.Typ.constr (Location.mknoloc (Longident.Lident name)) []
  in
  let emit_type =
    Ast_helper.Typ.arrow Nolabel (ty_constr "string") (ty_constr "unit")
  in
  Ast_helper.Prim.mk_decl
    ~prim:[ "caml_wire_emit" ]
    (Location.mknoloc wire_emit_name)
    emit_type

(* call a c function *)
let call_c_node input =
 let callc_function =
   Ast_helper.Exp.ident (Location.mknoloc (Longident.Lident wire_emit_name)) in
 let callc_arg = Ast_helper.Exp.constant {
   pconst_desc = (Pconst_string (input, Location.none, None));
   pconst_loc = Location.none} in
 Ast_helper.Exp.apply callc_function [ (Nolabel, callc_arg) ]
;;

(* makes an expression by passing down parent fields for all but env, desc, and type *)
let mk_exp (parent : Typedtree.expression) exp_env exp_type exp_desc : Typedtree.expression = 
  { exp_desc
  ; exp_loc=parent.exp_loc
  ; exp_extra=[]
  ; exp_type
  ; exp_env
  ; exp_attributes=parent.exp_attributes}

(* print a generic string input given typing env *)
let print_string_node env input = Typecore.type_expression env (
 let module_longident = Longident.Lident "Printf" in
 let print_longident = Longident.Ldot (Location.mknoloc module_longident, Location.mknoloc "printf") in
 let print_function = Ast_helper.Exp.ident (Location.mknoloc print_longident) in
 let print_arg = Ast_helper.Exp.constant {
   pconst_desc = (Pconst_string (input, Location.none, None));
   pconst_loc = Location.none} in
 Ast_helper.Exp.apply print_function [ (Nolabel, print_arg) ])
;;

(* wrapper to print a function call *)
(* let print_call_node (exp : Typedtree.expression) func args =
  let wire_data = Wire.format_function_call exp func args in
  print_string_node exp.exp_env (Sexplib.Sexp.to_string_hum (Wire.sexp_of_t wire_data)) *)


(* wrapper to run [exp] after doing some instrumentation [inject] (which should be unit) along with enclosing brackets. exp should be a Texp_apply to type check. *)
(* This returns an exp_desc, not an actual exp. *)
(* [inject] is already typed by the caller, which is the only place that has an
   environment carrying the spliced-in [wire_emit_name] primitive. *)
let inject_then_run_node (exp : Typedtree.expression) ~(inject : Typedtree.expression) =
  let res_uid = Shape.Uid.mk ~current_unit:(Env.get_current_unit ())
  in
  let res_ident = Ident.create_local "res" 
  in 
  let res_val_desc : Types.value_description =
    { val_type=exp.exp_type
    ; val_kind=Types.Val_reg
    ; val_loc= exp.exp_loc
    ; val_attributes=exp.exp_attributes
    ; val_uid=res_uid}
  in
  let env_with_res = Env.add_value res_ident res_val_desc exp.exp_env in 
  (* First print out the beginning bracket *)
  Typedtree.Texp_let (Asttypes.Nonrecursive, 
  [{
    vb_pat=
      { pat_desc=Tpat_any
      ; pat_loc=exp.exp_loc
      ; pat_extra = []
      ; pat_type = Predef.type_unit
      ; pat_env = exp.exp_env
      ; pat_attributes=exp.exp_attributes
      }
  ; vb_expr= print_string_node exp.exp_env "{"
  ; vb_rec_kind = Value_rec_types.Dynamic
  ; vb_attributes=exp.exp_attributes
  ; vb_loc=exp.exp_loc
  }], mk_exp exp exp.exp_env exp.exp_type 
  (* Then, run our instrumentation *)
  (Typedtree.Texp_let (Asttypes.Nonrecursive, 
  [{ 
    vb_pat= 
      { pat_desc=Tpat_any
      ; pat_loc=exp.exp_loc
      ; pat_extra = []
      ; pat_type = Predef.type_unit
      ; pat_env = exp.exp_env
      ; pat_attributes=exp.exp_attributes
      }
  ; vb_expr= inject
  ; vb_rec_kind = Value_rec_types.Dynamic
  ; vb_attributes=exp.exp_attributes
  ; vb_loc=exp.exp_loc
  }]
   (* Then evaluate the function and bind to res *)
  , mk_exp exp env_with_res exp.exp_type (Typedtree.Texp_let (Asttypes.Nonrecursive, 
  [{
    vb_pat=
    (* for me: Ident.t * string loc * Uid.t *)
      { pat_desc=Typedtree.Tpat_var (res_ident, Location.mknoloc "res", res_uid)
      ; pat_loc=exp.exp_loc
      ; pat_extra = []
      ; pat_type = exp.exp_type 
      ; pat_env = env_with_res
      ; pat_attributes=exp.exp_attributes
      }
  ; vb_expr= exp
  ; vb_rec_kind = Value_rec_types.Dynamic
  ; vb_attributes=exp.exp_attributes
  ; vb_loc=exp.exp_loc
  }]
   (* Print out the ending bracket *)
  , mk_exp exp env_with_res exp.exp_type (Typedtree.Texp_let (Asttypes.Nonrecursive, 
  [{
    vb_pat=
      { pat_desc=Tpat_any
      ; pat_loc=exp.exp_loc
      ; pat_extra = [] 
      ; pat_type = Predef.type_unit 
      ; pat_env = env_with_res 
      ; pat_attributes=exp.exp_attributes
      }
  ; vb_expr= print_string_node env_with_res "}"
  ; vb_rec_kind = Value_rec_types.Dynamic
  ; vb_attributes=exp.exp_attributes
  ; vb_loc=exp.exp_loc
  }]
   (* "return" the result *)
   (* for me: Path.t * Longident.t loc * Types.value_description *)
  , mk_exp exp env_with_res exp.exp_type 
    (Typedtree.Texp_ident 
      (Path.Pident res_ident
      , Location.mknoloc (Longident.Lident "res")
      , res_val_desc)
  ))))))))

(* Returns true if an event has occurred based on the function expression *)
let filter_func (_func : Typedtree.expression) = true

(* This is our special mapper that changes pexp_applies where an event occurs*)
let inject_mapper (wire_emit : Typedtree.primitive_description) =
  let super = Tast_mapper.default in

  (* [call_c_node] refers to [wire_emit_name], which is only in scope because
     [inject_instrumentation] splices the declaration into the structure. The
     environments hanging off the typedtree were snapshotted by [Typemod] before
     that happened, so the binding has to be added back before typing the call. *)
  let emit_node env payload =
    Typecore.type_expression
      (Env.add_value wire_emit.prim_id wire_emit.prim_val env)
      (call_c_node payload)
  in

  (* this function injects our custom instrumentation at every event *)
  let inject_expression self (exp : Typedtree.expression) =
    let recurse_down : Typedtree.expression = super.expr self exp in
    match exp.exp_desc with
    | Texp_apply (func, _) -> if filter_func func then
      ({  exp_desc = inject_then_run_node exp ~inject:(emit_node exp.exp_env "meow")
        ; exp_loc = exp.exp_loc
        ; exp_extra = exp.exp_extra
        ; exp_type = exp.exp_type
        ; exp_env = exp.exp_env
        ; exp_attributes = exp.exp_attributes
      } : Typedtree.expression) else recurse_down
    | _ -> recurse_down
  in
  { 
    Tast_mapper.default with 
    Tast_mapper.expr = inject_expression
  }

(* exposed for compile_commmon *)
let inject_instrumentation ~inject (tast : Typedtree.implementation) =
  if not inject then tast
  else
    let structure = tast.structure in
    (* translate the external against the environment the unit opened with, so
       that [string] and [unit] cannot have been shadowed by the unit itself *)
    let decl_env =
      match structure.str_items with
      | item :: _ -> item.str_env
      | [] -> structure.str_final_env
    in
    let wire_emit, _env =
      Typedecl.transl_prim_desc decl_env Location.none wire_external
    in
    let mapper = inject_mapper wire_emit in
    let structure = mapper.Tast_mapper.structure mapper structure in
    let wire_item : Typedtree.structure_item =
      { str_desc = Typedtree.Tstr_primitive wire_emit
      ; str_loc = Location.none
      ; str_env = decl_env }
    in
    (* [Tstr_primitive] contributes no field to the module block, so prepending
       it leaves [str_type] and the coercion [Typemod] computed still valid *)
    { tast with
      structure = { structure with str_items = wire_item :: structure.str_items } }
