(* the wire format: the record each event dumps, and the emit primitive
   every byte of the dump goes through *)
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
      (* [Omitted]: the application is abstracted over a labelled
         argument *)
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

  (* [external __wire_emit : string -> unit = "caml_wire_emit"], spliced
     per instrumented unit *)
  let emit_name = "__wire_emit"
  let emit_c_name = "caml_wire_emit"  (* defined in runtime/snapshot.c *)

  let emit_decl =
    let ty id =
      Ast_helper.Typ.constr (Location.mknoloc (Longident.Lident id)) []
    in
    Ast_helper.Prim.mk_decl ~prim:[ emit_c_name ]
      (Location.mknoloc emit_name)
      (Ast_helper.Typ.arrow Nolabel (ty "string") (ty "unit"))

  (* type [__wire_emit <payload>]: the typedtree's envs were snapshotted
     before [emit_decl] was spliced in, so re-add the prim *)
  let emit (prim : Typedtree.primitive_description) env payload =
    Typecore.type_expression
      (Env.add_value prim.prim_id prim.prim_val env)
      (Ast_helper.Exp.apply
         (Ast_helper.Exp.ident
            (Location.mknoloc (Longident.Lident emit_name)))
         [ ( Nolabel
           , Ast_helper.Exp.constant
               { pconst_desc =
                   Pconst_string (payload, Location.none, None)
               ; pconst_loc = Location.none } ) ])
end

(* the result binding each instrumented call introduces *)
let res_binder_name = "__vreplay_res"

(* frame markers, summed into depth by the reader ({ +1, } -1); emitted
   via [caml_wire_emit], never [Printf] (REVIEW_FINDINGS #2) *)
let frame_open = "{"
let frame_close = "}"

(* the record until real serialization lands, and the registry hand-off
   until its C entry point exists; records terminate themselves *)
let placeholder_record = "meow\n"
let root_placeholder = "ROOT\n"

(* ---- classification: which applications are events ---- *)

type mutability = Immutable | Mutable

(* where an event's traversal root lives: the result, or the mutated
   argument at that position of the argument list, read post-call *)
type root = Result | Argument of int

(* declaring units of the traversable structures (vreplay/README.md).
   [list]/[array] are predef-typed, not declared in their unit; they
   need their own rule and are not covered. *)
let ds_table : (string * mutability) list =
  [ "Stdlib__Map", Immutable
  ; "Stdlib__Hashtbl", Mutable
  ; "Stdlib__Queue", Mutable
  ; "Stdlib__Stack", Mutable ]

(* declaring unit of a uid. [Subst] copies uids verbatim, so [Item]
   survives [Map.Make], [include], [open] and aliasing.
   [Local_opaque_item] (functor params, first-class modules) names the
   using unit, not the origin: fail closed on it and the rest. *)
let uid_comp_unit : Shape.Uid.t -> string option = function
  | Shape.Uid.Item { comp_unit; _ } -> Some comp_unit
  | Shape.Uid.Compilation_unit _ | Shape.Uid.Local_opaque_item _
  | Shape.Uid.Internal | Shape.Uid.Predef _ -> None

(* [e]'s head type constructor is declared in [comp_unit] *)
let is_structure comp_unit (e : Typedtree.expression) =
  match Types.get_desc (Ctype.expand_head_nolink e.exp_env e.exp_type) with
  | Types.Tconstr (path, _, _) ->
    begin match Env.find_type path e.exp_env with
    | decl ->
      begin match uid_comp_unit decl.type_uid with
      | Some declaring_unit -> String.equal declaring_unit comp_unit
      | None -> false
      end
    | exception Not_found -> false
    end
  | _ -> false

(* partial application: the call leaves an arrow *)
let is_partial (e : Typedtree.expression) =
  match Types.get_desc (Ctype.expand_head_nolink e.exp_env e.exp_type) with
  | Types.Tarrow _ -> true
  | _ -> false

(* a mutable call's root: its first structure-typed argument. only an
   ident is safe to re-read post-call; otherwise skip the event. *)
let argument_root comp_unit args =
  let rec find i = function
    | [] -> None
    | (_, Typedtree.Omitted ()) :: rest -> find (i + 1) rest
    | (_, Typedtree.Arg (a : Typedtree.expression)) :: rest ->
      if not (is_structure comp_unit a) then find (i + 1) rest
      else begin match a.exp_desc with
      | Texp_ident _ -> Some (Argument i)
      | _ -> None
      end
  in
  find 0 args

(* is the application [exp] (function [func], arguments [args]) an
   event, and where is its root? returning the structure roots at the
   result: immutable manipulation plus mutable creators. any other
   total mutable-module call roots at its structure argument -- reads
   included, since types cannot tell [iter] from [remove] and [pop]
   does not return [unit]; re-observing beats missing a mutation. *)
let classify (exp : Typedtree.expression)
      (func : Typedtree.expression) args : root option =
  match func.exp_desc with
  | Texp_ident (_, _, vd) ->
    begin match uid_comp_unit vd.val_uid with
    | None -> None
    | Some comp_unit ->
      begin match List.assoc_opt comp_unit ds_table with
      | None -> None
      | Some Immutable ->
        if is_structure comp_unit exp then Some Result else None
      | Some Mutable ->
        if is_structure comp_unit exp then Some Result
        else if is_partial exp then None
        else argument_root comp_unit args
      end
    end
  | _ -> None

(* ---- code generation ---- *)

(* wrap [exp] (a Texp_apply) in frame markers, [inject] before the call
   and [inject_after] after it, with the result bound to
   [res_binder_name]; a raising call skips everything after itself.
   returns an exp_desc. *)
let instrument_call ?inject_after (exp : Typedtree.expression)
      ~(emit : Env.t -> string -> Typedtree.expression)
      ~(inject : Env.t -> Typedtree.expression) =
  let res_uid = Shape.Uid.mk ~current_unit:(Env.get_current_unit ()) in
  let res_ident = Ident.create_local res_binder_name in
  let res_val_desc : Types.value_description =
    { val_type=exp.exp_type
    ; val_kind=Types.Val_reg
    ; val_loc= exp.exp_loc
    ; val_attributes=[]
    ; val_uid=res_uid}
  in
  let env_with_res = Env.add_value res_ident res_val_desc exp.exp_env in
  (* synthesized node: [exp] gives only the loc; attributes stay empty *)
  let mk env ty desc : Typedtree.expression =
    { exp_desc=desc
    ; exp_loc=exp.exp_loc
    ; exp_extra=[]
    ; exp_type=ty
    ; exp_env=env
    ; exp_attributes=[]}
  in
  (* evaluate [rhs] for effect, then [body]. the rhs needn't be unit:
     pat_type is never read, [Matching.for_let] compiles [Tpat_any] to
     an [Lsequence]. *)
  let seq env (rhs : Typedtree.expression) body =
    mk env exp.exp_type (Typedtree.Texp_let
      (Asttypes.Nonrecursive,
      [{ vb_pat=
           { pat_desc=Tpat_any
           ; pat_loc=exp.exp_loc
           ; pat_extra = []
           ; pat_type = rhs.exp_type
           ; pat_env = env
           ; pat_attributes=[]
           }
       ; vb_expr= rhs
       ; vb_rec_kind = Value_rec_types.Dynamic
       ; vb_attributes=[]
       ; vb_loc=exp.exp_loc
       }], body))
  in
  (* [tail] accumulates inside-out *)
  let tail =
    mk env_with_res exp.exp_type
      (Typedtree.Texp_ident
        (Path.Pident res_ident
        , Location.mknoloc (Longident.Lident res_binder_name)
        , res_val_desc))
  in
  let tail = seq env_with_res (emit env_with_res frame_close) tail in
  let tail =
    match inject_after with
    | None -> tail
    | Some hook -> seq env_with_res (hook env_with_res) tail
  in
  let tail =
    mk env_with_res exp.exp_type (Typedtree.Texp_let
      (Asttypes.Nonrecursive,
      [{ vb_pat=
           { pat_desc=
               Typedtree.Tpat_var
                 (res_ident, Location.mknoloc res_binder_name, res_uid)
           ; pat_loc=exp.exp_loc
           ; pat_extra = []
           ; pat_type = exp.exp_type
           ; pat_env = env_with_res
           ; pat_attributes=[]
           }
       ; vb_expr= exp
       ; vb_rec_kind = Value_rec_types.Dynamic
       ; vb_attributes=[]
       ; vb_loc=exp.exp_loc
       }], tail))
  in
  (seq exp.exp_env (emit exp.exp_env frame_open)
     (seq exp.exp_env (inject exp.exp_env) tail)).exp_desc

(* rewrite each [Texp_apply] that [classify] marks as an event *)
let inject_mapper (emit_prim : Typedtree.primitive_description) =
  let super = Tast_mapper.default in
  let emit env payload = Wire.emit emit_prim env payload in

  let inject_expression self (exp : Typedtree.expression) =
    let recurse_down : Typedtree.expression = super.expr self exp in
    match exp.exp_desc with
    | Texp_apply (func, args) ->
      begin match classify exp func args with
      | None -> recurse_down
      (* placeholders until the registry hand-off lands; the root kind
         says what that hook will read *)
      | Some Result | Some (Argument _) ->
        { exp with
          exp_desc =
            instrument_call recurse_down ~emit
              ~inject:(fun env -> emit env placeholder_record)
              ~inject_after:(fun env -> emit env root_placeholder) }
      end
    | _ -> recurse_down
  in
  { super with Tast_mapper.expr = inject_expression }

(* exposed for compile_common *)
let inject_instrumentation ~inject (tast : Typedtree.implementation) =
  if not inject then tast
  else
    let structure = tast.structure in
    (* type the declaration in the env the unit opened with, so [string]
       and [unit] cannot have been shadowed by the unit itself *)
    let decl_env =
      match structure.str_items with
      | item :: _ -> item.str_env
      | [] -> structure.str_final_env
    in
    let emit_prim, _env =
      Typedecl.transl_prim_desc decl_env Location.none Wire.emit_decl
    in
    let mapper = inject_mapper emit_prim in
    let structure = mapper.Tast_mapper.structure mapper structure in
    let emit_item : Typedtree.structure_item =
      { str_desc = Typedtree.Tstr_primitive emit_prim
      ; str_loc = Location.none
      ; str_env = decl_env }
    in
    (* [Tstr_primitive] adds no field to the module block, so prepending
       it leaves [str_type] and [Typemod]'s coercion valid *)
    { tast with
      structure =
        { structure with str_items = emit_item :: structure.str_items } }
