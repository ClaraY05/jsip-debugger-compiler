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
end

(* the [external] we splice into each instrumented structure. [call_c_node]
   refers to it by this name, so the declaration and the call sites must
   agree. *)
let wire_emit_name = "__wire_emit"

(* the C primitive behind it, defined in runtime/snapshot.c *)
let wire_emit_prim_name = "caml_wire_emit"

let wire_external =
  let ty_constr name =
    Ast_helper.Typ.constr (Location.mknoloc (Longident.Lident name)) []
  in
  let emit_type =
    Ast_helper.Typ.arrow Nolabel (ty_constr "string") (ty_constr "unit")
  in
  Ast_helper.Prim.mk_decl
    ~prim:[ wire_emit_prim_name ]
    (Location.mknoloc wire_emit_name)
    emit_type

(* the binding that holds an instrumented call's result. future call sites
   will refer to it by name, so declaration and uses must agree. *)
let res_binder_name = "__vreplay_res"

(* the untyped call [__wire_emit <input>] *)
let call_c_node input =
 let callc_function =
   Ast_helper.Exp.ident (Location.mknoloc (Longident.Lident wire_emit_name)) in
 let callc_arg = Ast_helper.Exp.constant {
   pconst_desc = (Pconst_string (input, Location.none, None));
   pconst_loc = Location.none} in
 Ast_helper.Exp.apply callc_function [ (Nolabel, callc_arg) ]

(* frame markers: the reader sums these to get call depth ({ is +1, } is -1),
   so they have to reach the dump in call order. emit them with
   [caml_wire_emit], not [Printf.printf] -- printf buffers in OCaml's stdout
   channel and only flushes at exit, so mixing the two put every marker in the
   run after every record. *)
let frame_open = "{"
let frame_close = "}"

(* stand-in until we can serialize a real record. note the trailing newline --
   whatever replaces this has to terminate its own record *)
let placeholder_record = "meow\n"

(* stand-in for the traversal-root hand-off, until the runtime registry's
   C entry point exists. same newline rule. *)
let root_placeholder = "ROOT\n"

(* a synthesized expression: parent supplies only the loc. attributes stay
   empty so a user attribute is not replicated onto instrumentation nodes *)
let mk_exp (parent : Typedtree.expression) exp_env exp_type exp_desc
  : Typedtree.expression =
  { exp_desc
  ; exp_loc=parent.exp_loc
  ; exp_extra=[]
  ; exp_type
  ; exp_env
  ; exp_attributes=[]}

(* wrap [exp] (a Texp_apply) in frame markers plus instrumentation; returns
   an exp_desc. [inject] and [inject_after] produce arbitrary already-typed
   expressions -- what they do is deliberately not our business; they own
   record termination, we own the markers. each receives the env at its
   sequencing point: [inject] before the call, [inject_after] with the
   result bound to [res_binder_name] -- it can observe the result, and a
   raising call skips it. [emit] comes from the caller, whose env has
   [wire_emit_name] in scope. *)
let inject_then_run_node ?inject_after (exp : Typedtree.expression)
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
  (* evaluate [rhs] for effect, then run [body]. the rhs needn't be unit:
     pat_type is never read -- [Matching.for_let] compiles a [Tpat_any]
     binding to an [Lsequence]. *)
  let seq env (rhs : Typedtree.expression) body =
    mk_exp exp env exp.exp_type (Typedtree.Texp_let
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
  (* [res_binder_name] read back: the whole wrapper's value *)
  let read_result =
    mk_exp exp env_with_res exp.exp_type
      (Typedtree.Texp_ident
        (Path.Pident res_ident
        , Location.mknoloc (Longident.Lident res_binder_name)
        , res_val_desc))
  in
  let close_then_return =
    seq env_with_res (emit env_with_res frame_close) read_result
  in
  let after_close_then_return =
    match inject_after with
    | None -> close_then_return
    | Some hook -> seq env_with_res (hook env_with_res) close_then_return
  in
  let bind_result_then_rest =
    mk_exp exp env_with_res exp.exp_type (Typedtree.Texp_let
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
       }], after_close_then_return))
  in
  (* the opening frame marker, then the record, then the call *)
  let whole =
    seq exp.exp_env (emit exp.exp_env frame_open)
      (seq exp.exp_env (inject exp.exp_env) bind_result_then_rest)
  in
  whole.exp_desc

(* [Immutable] ops return the structure: the traversal root is the result.
   [Mutable] (phase 2) will root at the mutated argument instead; declaring
   the constructor before anything builds it trips warning 37. *)
type mutability = Immutable

(* the "DS traversal info table" (vreplay/README.md): declaring units of
   the structures the replay can traverse. extend with e.g.
   "Stdlib__Set", Immutable. *)
let ds_table : (string * mutability) list =
  [ "Stdlib__Map", Immutable ]

(* where an event's traversal root lives. phase 2 adds [Argument of int]
   for mutable DS -- then the index must skip [Omitted]s, and only an
   argument that is syntactically an ident can be re-read post-call
   without re-evaluating or reordering (application is right-to-left). *)
type root = Result

(* the unit a declaration originates from: [Subst] copies uids verbatim,
   so this survives functor application, [include], [open] and aliasing.
   [Local_opaque_item] (functor params, first-class modules) names the
   *using* unit, not the origin -- fail closed on it and the rest. *)
let uid_comp_unit : Shape.Uid.t -> string option = function
  | Shape.Uid.Item { comp_unit; _ } -> Some comp_unit
  | Shape.Uid.Compilation_unit _ | Shape.Uid.Local_opaque_item _
  | Shape.Uid.Internal | Shape.Uid.Predef _ -> None

(* the result type's head constructor is declared in [comp_unit]: what an
   immutable-DS event returns. excludes queries, iteration and partial
   application in one check; over-approximates harmlessly on e.g. [find]
   over a map of maps (re-observes an existing map). *)
let returns_the_structure comp_unit (exp : Typedtree.expression) =
  match
    Types.get_desc (Ctype.expand_head_nolink exp.exp_env exp.exp_type)
  with
  | Types.Tconstr (path, _, _) ->
    begin match Env.find_type path exp.exp_env with
    | decl ->
      begin match uid_comp_unit decl.type_uid with
      | Some type_unit -> String.equal type_unit comp_unit
      | None -> false
      end
    | exception Not_found -> false
    end
  | _ -> false

(* is the application [exp] (function part [func]) a DS event, and if so
   where is its traversal root? deliberate misses: [M.empty] (not an
   application; observed at first manipulation), functor-param /
   first-class-module access, rebound functions ([let add = M.add]). *)
let classify (exp : Typedtree.expression)
      (func : Typedtree.expression) : root option =
  match func.exp_desc with
  | Texp_ident (_, _, vd) ->
    begin match uid_comp_unit vd.val_uid with
    | None -> None
    | Some comp_unit ->
      begin match List.assoc_opt comp_unit ds_table with
      | None -> None
      | Some Immutable ->
        if returns_the_structure comp_unit exp then Some Result
        else None
      end
    end
  | _ -> None

(* the mapper that rewrites each [Texp_apply] where an event occurs *)
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
    | Texp_apply (func, _) ->
      begin match classify exp func with
      | None -> recurse_down
      | Some Result ->
        { exp with
          exp_desc =
            inject_then_run_node recurse_down ~emit:emit_node
              ~inject:(fun env -> emit_node env placeholder_record)
              ~inject_after:(fun env -> emit_node env root_placeholder) }
      end
    | _ -> recurse_down
  in
  {
    super with
    Tast_mapper.expr = inject_expression
  }

(* exposed for compile_common *)
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
