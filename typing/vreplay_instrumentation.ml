module Wire = struct
  type t = {
      location: string
      ; function_type: string
      ; function_data: string
      ; argument_list: (string * string) list
  }
  [@@deriving sexp]

  let format_function_call
        (exp : Typedtree.expression) (func : Typedtree.expression) args =
    let location = Format.asprintf "%a" Location.print_loc exp.exp_loc in
    let function_type, function_data =
      match func.exp_desc with
      | Texp_ident (_, lid, _) ->
        "Function_name", Format.asprintf "%a" Pprintast.longident lid.txt
      | _ ->
        "Unnamed",
        Format.asprintf "%a" Pprintast.expression
          (Untypeast.untype_expression func)
    in
    let argument_list =
      (* [Texp_apply] hands us an [apply_arg], not an expression: it's
         [Omitted] for an argument the application is abstracted over, i.e. a
         labelled partial application *)
      let format_arg (arg_label, arg) =
        let argument_data =
          match (arg : Typedtree.apply_arg) with
          | Arg argument ->
            Format.asprintf "%a" Pprintast.expression
              (Untypeast.untype_expression argument)
          | Omitted () -> "OMITTED"
        in
        match (arg_label : Asttypes.arg_label) with
        | Nolabel -> "NO_LABEL", argument_data
        | Labelled label -> "LABELLED:" ^ label, argument_data
        | Optional label -> "OPTIONAL:" ^ label, argument_data
      in
      List.map format_arg args
    in
    {location; function_type; function_data; argument_list}
  ;;
end

(* the [external] we splice into each instrumented structure. [call_c_node]
   refers to it by this name, so the declaration and the call sites must
   agree. *)
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

(* frame markers: the reader sums these to get call depth ({ is +1, } is -1),
   so they have to reach the dump in call order. emit them with
   [caml_wire_emit], not [Printf.printf] -- printf buffers in OCaml's stdout
   channel and only flushes at exit, so mixing the two put every marker in the
   run after every record. *)
let frame_open = "{"
let frame_close = "}"

(* makes an expression by passing down parent fields for all but env, desc,
   and type *)
let mk_exp (parent : Typedtree.expression) exp_env exp_type exp_desc
  : Typedtree.expression =
  { exp_desc
  ; exp_loc=parent.exp_loc
  ; exp_extra=[]
  ; exp_type
  ; exp_env
  ; exp_attributes=parent.exp_attributes}

(* the module a qualified application comes from: [Map.add] -> "Map",
   [Stdlib.Map.add] -> "Map". Used as the [~ds] key into [Vreplay.ds_info]. *)
let ds_module (func : Typedtree.expression) : string option =
  (* [Longident.t] here is [Lident of string | Ldot of t loc * string loc
     | Lapply of t loc * t loc], so the located components need [.txt]. *)
  let last_mod = function
    | Longident.Lident m -> Some m
    | Longident.Ldot (_, m) -> Some m.txt
    | Longident.Lapply (_, _) -> None
  in
  match func.exp_desc with
  | Texp_ident (_, lid, _) ->
    (match lid.txt with
     | Longident.Ldot (path, _fn) -> last_mod path.txt
     | _ -> None)
  | _ -> None

(* Build and type-check [Vreplay.snapshot ~loc ~fn ~ds res] in [env]. [env]
   must have [res] bound (we run this in [env_with_res]); [Vreplay] is resolved
   by ordinary name resolution against the instrumented unit's load path, the
   same way the emit path resolves [__wire_emit]. *)
let snapshot_call_node env ~loc ~fn ~ds =
  let str s =
    Ast_helper.Exp.constant
      { pconst_desc = Pconst_string (s, Location.none, None)
      ; pconst_loc = Location.none }
  in
  let snapshot_fn =
    Ast_helper.Exp.ident
      (Location.mknoloc
         (Longident.Ldot
            ( Location.mknoloc (Longident.Lident "Vreplay")
            , Location.mknoloc "snapshot" )))
  in
  let res_arg =
    Ast_helper.Exp.ident (Location.mknoloc (Longident.Lident "res"))
  in
  Typecore.type_expression env
    (Ast_helper.Exp.apply snapshot_fn
       [ (Asttypes.Labelled "loc", str loc)
       ; (Asttypes.Labelled "fn",  str fn)
       ; (Asttypes.Labelled "ds",  str ds)
       ; (Asttypes.Nolabel, res_arg) ])

(* Wrap [exp] as:

     let () = emit "{"            (* opening frame marker *)
     in let res = exp             (* evaluate the call, bind its result *)
     in let () = snapshot res     (* observe the RESULT's side effects *)
     in let () = emit "}"         (* closing frame marker *)
     in res                       (* hand the result back unchanged *)

   Returns an [exp_desc], not an [expression]. The snapshot runs AFTER [res] is
   bound so it sees the value the call produced. [emit] is passed in because
   only the caller's env has [wire_emit_name] in scope; [snapshot] is passed
   [env_with_res] because it references [res]. *)
let inject_then_run_node (exp : Typedtree.expression)
      ~(emit : Env.t -> string -> Typedtree.expression)
      ~(snapshot : Env.t -> Typedtree.expression) =
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
  let snapshot_exp = snapshot env_with_res in
  (* First emit the opening frame marker *)
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
  ; vb_expr= emit exp.exp_env frame_open
  ; vb_rec_kind = Value_rec_types.Dynamic
  ; vb_attributes=exp.exp_attributes
  ; vb_loc=exp.exp_loc
  }], mk_exp exp exp.exp_env exp.exp_type
  (* Evaluate the function and bind to res FIRST, so the snapshot can observe
     the value it produced. *)
  (Typedtree.Texp_let (Asttypes.Nonrecursive,
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
   (* Then run the snapshot on [res]. pat_type comes from [snapshot_exp] rather
      than [Predef.type_unit] so it isn't forced to be unit -- the value is
      dropped either way, since [Matching.for_let] turns a [Tpat_any] binding
      into an [Lsequence] without ever reading pat_type. *)
  , mk_exp exp env_with_res exp.exp_type (Typedtree.Texp_let
  (Asttypes.Nonrecursive,
  [{
    vb_pat=
      { pat_desc=Tpat_any
      ; pat_loc=exp.exp_loc
      ; pat_extra = []
      ; pat_type = snapshot_exp.exp_type
      ; pat_env = env_with_res
      ; pat_attributes=exp.exp_attributes
      }
  ; vb_expr= snapshot_exp
  ; vb_rec_kind = Value_rec_types.Dynamic
  ; vb_attributes=exp.exp_attributes
  ; vb_loc=exp.exp_loc
  }]
   (* Emit the closing frame marker *)
  , mk_exp exp env_with_res exp.exp_type (Typedtree.Texp_let
  (Asttypes.Nonrecursive,
  [{
    vb_pat=
      { pat_desc=Tpat_any
      ; pat_loc=exp.exp_loc
      ; pat_extra = []
      ; pat_type = Predef.type_unit
      ; pat_env = env_with_res
      ; pat_attributes=exp.exp_attributes
      }
  ; vb_expr= emit env_with_res frame_close
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
     environments hanging off the typedtree were snapshotted by [Typemod]
     before that happened, so the binding has to be added back before typing
     the call. *)
  let emit_node env payload =
    Typecore.type_expression
      (Env.add_value wire_emit.prim_id wire_emit.prim_val env)
      (call_c_node payload)
  in

  (* this function injects our custom instrumentation at every event *)
  let inject_expression self (exp : Typedtree.expression) =
    let recurse_down : Typedtree.expression = super.expr self exp in
    match exp.exp_desc with
    | Texp_apply (func, args) -> if filter_func func then
      let wire = Wire.format_function_call exp func args in
      let ds = match ds_module func with Some m -> m | None -> "" in
      ({  exp_desc =
            inject_then_run_node recurse_down ~emit:emit_node
              ~snapshot:(fun env ->
                snapshot_call_node env
                  ~loc:wire.Wire.location ~fn:wire.Wire.function_data ~ds)
        ; exp_loc = exp.exp_loc
        ; exp_extra = exp.exp_extra
        ; exp_type = exp.exp_type
        ; exp_env = exp.exp_env
        ; exp_attributes = exp.exp_attributes
      } : Typedtree.expression) else recurse_down
    | _ -> recurse_down
  in
  {
    super with
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
      structure =
        { structure with str_items = wire_item :: structure.str_items } }
