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

(* name of the binding that holds an instrumented call's result. the
   follow-up that hands the traversal root to the runtime registry will
   refer to it by name (typing a call against the env it is bound in),
   so the declaration in [inject_then_run_node] and those call sites
   must agree, like [wire_emit_name] above. *)
let res_binder_name = "__vreplay_res"

(* call a c function *)
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

(* stand-in for the traversal-root hand-off: marks where in the frame
   the call passing [res_binder_name]'s value to the runtime registry
   will run, once that C entry point exists. same newline rule. *)
let root_placeholder = "ROOT\n"

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

(* wrapper to run [exp] after doing some instrumentation [inject] along with
   enclosing frame markers. exp should be a Texp_apply to type check. *)
(* This returns an exp_desc, not an actual exp. *)
(* [inject] and [inject_after] produce arbitrary already-typed expressions --
   we deliberately don't care what they do or what type they have, since the
   real instrumentation will be a lot more than one emit. they write records
   and terminate them; we own only the markers either side. each is handed
   the env at its sequencing point: [inject] the env before the call,
   [inject_after] the env in which [res_binder_name] holds the call's
   result -- it runs between that binding and the closing marker, so it can
   observe the result, and if the call raises it never runs. [emit] is
   passed in because only the caller's env has [wire_emit_name] in scope. *)
let inject_then_run_node ?inject_after (exp : Typedtree.expression)
      ~(emit : Env.t -> string -> Typedtree.expression)
      ~(inject : Env.t -> Typedtree.expression) =
  let res_uid = Shape.Uid.mk ~current_unit:(Env.get_current_unit ()) in
  let res_ident = Ident.create_local res_binder_name in
  let res_val_desc : Types.value_description =
    { val_type=exp.exp_type
    ; val_kind=Types.Val_reg
    ; val_loc= exp.exp_loc
    ; val_attributes=exp.exp_attributes
    ; val_uid=res_uid}
  in
  let env_with_res = Env.add_value res_ident res_val_desc exp.exp_env in
  (* evaluate [rhs] for effect, then run [body]. pat_type comes from [rhs]
     rather than [Predef.type_unit] so the rhs isn't forced to be unit --
     the value is dropped either way, since [Matching.for_let] turns a
     [Tpat_any] binding into an [Lsequence] without ever reading
     pat_type. *)
  let seq env (rhs : Typedtree.expression) body =
    mk_exp exp env exp.exp_type (Typedtree.Texp_let
      (Asttypes.Nonrecursive,
      [{ vb_pat=
           { pat_desc=Tpat_any
           ; pat_loc=exp.exp_loc
           ; pat_extra = []
           ; pat_type = rhs.exp_type
           ; pat_env = env
           ; pat_attributes=exp.exp_attributes
           }
       ; vb_expr= rhs
       ; vb_rec_kind = Value_rec_types.Dynamic
       ; vb_attributes=exp.exp_attributes
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
  (* the post-call instrumentation, if any, goes between the result
     binding and the closing marker *)
  let after_close_then_return =
    match inject_after with
    | None -> close_then_return
    | Some hook -> seq env_with_res (hook env_with_res) close_then_return
  in
  (* evaluate the call and bind its result *)
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
           ; pat_attributes=exp.exp_attributes
           }
       ; vb_expr= exp
       ; vb_rec_kind = Value_rec_types.Dynamic
       ; vb_attributes=exp.exp_attributes
       ; vb_loc=exp.exp_loc
       }], after_close_then_return))
  in
  (* the opening frame marker, then the record, then the call *)
  let whole =
    seq exp.exp_env (emit exp.exp_env frame_open)
      (seq exp.exp_env (inject exp.exp_env) bind_result_then_rest)
  in
  whole.exp_desc

(* whether operations on a structure return it (traverse the result) or
   update it in place (traverse the mutated argument, after the call).
   [Mutable] joins in phase 2 along with the argument root -- declaring
   it before anything constructs it would trip warning 37. *)
type mutability = Immutable

(* the "DS traversal info table" (vreplay/README.md): the compilation
   units whose structures the replay knows how to traverse, keyed on the
   unit that declared the functions and types -- see [uid_comp_unit].
   phase 1 is Map only; "Stdlib__Set", Immutable would be one more line,
   mutable modules ("Stdlib__Hashtbl") also need the phase-2 root. *)
let ds_table : (string * mutability) list =
  [ "Stdlib__Map", Immutable ]

(* where an event's traversal root lives. [Result]: the call returns the
   new structure (immutable DS). phase 2, mutable DS, adds
   [Argument of int]: the mutated argument, read after the call. two
   traps to remember then: the index must count only [Arg]s ([Omitted]
   sits in place in the list on labelled partial application), and
   referring to an argument post-call must not re-evaluate or reorder it
   -- arguments are applied right-to-left, so the safe subset is an
   argument that is syntactically an ident. *)
type root = Result

(* the compilation unit a declaration originates from. uids are minted
   where a declaration is written and copied verbatim by [Subst], so
   they survive functor application, [include], [open] and aliasing:
   [Map.Make(K).add] still says "Stdlib__Map". [Local_opaque_item] is
   the deliberate exception -- it marks access through a functor
   parameter or a first-class module, where the true origin is
   unknowable at compile time, and it carries the *using* unit -- so it
   must not count as provenance. fail closed on it and the rest. *)
let uid_comp_unit : Shape.Uid.t -> string option = function
  | Shape.Uid.Item { comp_unit; _ } -> Some comp_unit
  | Shape.Uid.Compilation_unit _ | Shape.Uid.Local_opaque_item _
  | Shape.Uid.Internal | Shape.Uid.Predef _ -> None

(* an immutable-DS call is an event iff it returns the structure: the
   result type's head constructor must be declared in the same unit as
   the function. the one check excludes queries ([find]/[mem]/
   [cardinal]), iteration ([iter]/[bindings]/[to_seq]) and partial
   application (the head is an arrow, including the [Omitted]-argument
   form). known over-approximations, both harmless in that they only
   re-observe a structure that already exists: [find] on a map whose
   values are maps, and [fold] whose accumulator is a map. *)
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

(* Decides whether the application [exp], whose function part is [func],
   is an event, and if so where its traversal root lives. [None] means
   don't instrument. deliberate misses: [M.empty] (an ident, not an
   application -- the map is observed at its first manipulation), access
   through functor parameters and first-class modules, and functions
   rebound outside the module ([let add = M.add]). *)
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
