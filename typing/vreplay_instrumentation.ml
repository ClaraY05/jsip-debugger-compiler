(* the wire format: the record each event dumps, and the emit primitive
   every byte of the dump goes through *)
module Wire = struct
  (* Field shapes mirror the interface repo's own types so the sexp
     renders (Sexp.sexp_of_loc/fn/args) match what ppx_sexp_conv derives
     there: [location] is its Location.t components (file, line, char
     range), the first component of [function_info] and of each argument
     triple is a constructor name of its Function_info.t / Argument.t. *)
  type t = {
      location: string * int * int * int
      ; function_info: string * string
      ; argument_list: (string * string * string) list
  }

  let location_of (exp : Typedtree.expression) =
    let start = exp.exp_loc.Location.loc_start in
    let stop = exp.exp_loc.Location.loc_end in
    ( start.Lexing.pos_fname
    , start.Lexing.pos_lnum
    , start.Lexing.pos_cnum - start.Lexing.pos_bol
    , stop.Lexing.pos_cnum - stop.Lexing.pos_bol )

  (* A [let] binding observed for its own sake.  There is no function
     here, so the bound expression's own source text stands in for one
     and the argument list is empty. *)
  let format_binding (exp : Typedtree.expression) =
    { location = location_of exp
    ; function_info =
        ( "Unnamed"
        , Format.asprintf "%a" Pprintast.expression
            (Untypeast.untype_expression exp) )
    ; argument_list = [] }

  let format_function_call
        (exp : Typedtree.expression) (func : Typedtree.expression) args =
    let location = location_of exp in
    let function_info =
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
        | Nolabel -> "No_label", "", argument_data
        | Labelled label -> "Labelled", label, argument_data
        | Optional label -> "Optional", label, argument_data
      in
      List.map format_arg args
    in
    {location; function_info; argument_list}

  (* [external __wire_emit : string -> unit = "caml_wire_emit"], spliced
     per instrumented unit *)
  let emit_name = "__wire_emit"
  let emit_c_name = "caml_wire_emit"  (* defined in runtime/snapshot.c *)

  let emit_decl =
    let ty id =
      Ast_helper.Typ.constr (Location.mknoloc (Longident.Lident id)) []
    in
    Ast_helper.Val.mk ~prim:[ emit_c_name ]
      (Location.mknoloc emit_name)
      (Ast_helper.Typ.arrow Nolabel (ty "string") (ty "unit"))

  (* type [__wire_emit <payload>]: the typedtree's envs were snapshotted
     before [emit_decl] was spliced in, so re-add the prim *)
  let emit (prim : Typedtree.value_description) env payload =
    Typecore.type_expression
      (Env.add_value prim.val_id prim.val_val env)
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

(* ---- classification: which applications are events ---- *)

type mutability = Immutable | Mutable

(* where an event's traversal root lives: the result, or the mutated
   argument at that position of the argument list, read post-call *)
type root = Result | Argument of int

(* The unit a tracked structure's TYPE is declared in, and the catalogue
   name of the REPRESENTATION that type has -- these names MUST mirror
   [Data_structure.of_name] in vreplay/data_structure.ml.  This is what
   names a root, because the module a call went through says nothing
   about what the call hands back: [Core.Linked_queue] hands back a
   [Stdlib.Queue.t], and [Queue.pop] on a queue of maps hands back a
   map.  [Core.Map.t] is an alias of [Base.Map.t] and expands to it, but
   a Core module whose type stopped being transparent would resolve to
   its own unit, so both are listed.  [list]/[array] are predef-typed,
   declared in no unit at all; they would need their own rule and are
   not covered. *)
let ds_of_type_unit : (string * string) list =
  [ "Stdlib__Map", "Map"
  ; "Stdlib__Set", "Set"
  ; "Stdlib__Queue", "Queue"
  ; "Stdlib__Hashtbl", "Hashtbl"
  ; "Stdlib__Stack", "Stack"
  ; "Stdlib__Dynarray", "Dynarray"
  (* Base and Core: BOTH a module's implementation unit and the _intf
     unit its module type came from, because which one a value's type
     resolves to is a fact about how the library was assembled, not
     about the call site -- [Base.Map.t] lands on [Base__Map],
     [Base.Queue.t] on [Base__Queue_intf].  [Linked_queue] is
     deliberately absent: its values are stdlib queues and must resolve
     as such. *)
  ; "Base__Map", "Core_map"
  ; "Base__Map_intf", "Core_map"
  ; "Core__Map", "Core_map"
  ; "Core__Map_intf", "Core_map"
  ; "Base__Set", "Core_set"
  ; "Base__Set_intf", "Core_set"
  ; "Core__Set", "Core_set"
  ; "Core__Set_intf", "Core_set"
  ; "Base__Hashtbl", "Core_hashtbl"
  ; "Base__Hashtbl_intf", "Core_hashtbl"
  ; "Core__Hashtbl", "Core_hashtbl"
  ; "Core__Hashtbl_intf", "Core_hashtbl"
  ; "Base__Hash_set", "Core_hash_set"
  ; "Base__Hash_set_intf", "Core_hash_set"
  ; "Core__Hash_set", "Core_hash_set"
  ; "Core__Hash_set_intf", "Core_hash_set"
  ; "Base__Queue", "Core_queue"
  ; "Base__Queue_intf", "Core_queue"
  ; "Core__Queue", "Core_queue"
  ; "Core__Queue_intf", "Core_queue"
  ; "Base__Stack", "Core_stack"
  ; "Base__Stack_intf", "Core_stack"
  ; "Core__Stack", "Core_stack"
  ; "Core__Stack_intf", "Core_stack"
  ; "Core__Deque", "Core_deque"
  ; "Core__Deque_intf", "Core_deque"
  ; "Core__Fdeque", "Core_fdeque"
  ; "Core__Fdeque_intf", "Core_fdeque"
  ; "Core__Fqueue", "Core_fdeque"
  ; "Core__Doubly_linked", "Core_doubly_linked"
  ; "Core__Doubly_linked_intf", "Core_doubly_linked"
  ; "Core__Hash_queue", "Core_hash_queue"
  ; "Core__Hash_queue_intf", "Core_hash_queue" ]

(* The modules whose calls are events: the unit a called function is
   declared in -- for Base and Core usually the _intf unit its module
   type came from, not the implementation -- the call's mutability, and
   the catalogue entries the module OPERATES ON.

   A mutable call re-observes its container arguments, but only those:
   an argument of some other tracked kind is an element being handed
   over, which the call cannot have mutated ([Queue.add m q] moves [m]
   into [q], it does not change [m]).  Naming catalogue ENTRIES rather
   than units is what lets one shared interface serve several
   representations -- Base's Queue_intf backs both [Base.Queue], a ring
   buffer, and [Linked_queue], a stdlib queue.

   [Base__Container_intf] is deliberately absent: the operations every
   container shares ([length], [iter], [fold]) only read, so nothing
   they are handed can have changed. *)
let ds_table : (string * (mutability * string list)) list =
  [ "Stdlib__Map", (Immutable, [ "Map" ])
  ; "Stdlib__Set", (Immutable, [ "Set" ])
  ; "Stdlib__Queue", (Mutable, [ "Queue" ])
  ; "Stdlib__Hashtbl", (Mutable, [ "Hashtbl" ])
  ; "Stdlib__Stack", (Mutable, [ "Stack" ])
  ; "Stdlib__Dynarray", (Mutable, [ "Dynarray" ])
  ; "Base__Map", (Immutable, [ "Core_map" ])
  ; "Base__Map_intf", (Immutable, [ "Core_map" ])
  ; "Core__Map", (Immutable, [ "Core_map" ])
  ; "Core__Map_intf", (Immutable, [ "Core_map" ])
  ; "Base__Set", (Immutable, [ "Core_set" ])
  ; "Base__Set_intf", (Immutable, [ "Core_set" ])
  ; "Core__Set", (Immutable, [ "Core_set" ])
  ; "Core__Set_intf", (Immutable, [ "Core_set" ])
  ; "Base__Hashtbl", (Mutable, [ "Core_hashtbl" ])
  ; "Base__Hashtbl_intf", (Mutable, [ "Core_hashtbl" ])
  ; "Core__Hashtbl", (Mutable, [ "Core_hashtbl" ])
  ; "Core__Hashtbl_intf", (Mutable, [ "Core_hashtbl" ])
  ; "Base__Hash_set", (Mutable, [ "Core_hash_set" ])
  ; "Base__Hash_set_intf", (Mutable, [ "Core_hash_set" ])
  ; "Core__Hash_set", (Mutable, [ "Core_hash_set" ])
  ; "Core__Hash_set_intf", (Mutable, [ "Core_hash_set" ])
  ; "Base__Queue", (Mutable, [ "Core_queue"; "Queue" ])
  ; "Base__Queue_intf", (Mutable, [ "Core_queue"; "Queue" ])
  ; "Core__Queue", (Mutable, [ "Core_queue"; "Queue" ])
  ; "Core__Queue_intf", (Mutable, [ "Core_queue"; "Queue" ])
  ; "Base__Stack", (Mutable, [ "Core_stack" ])
  ; "Base__Stack_intf", (Mutable, [ "Core_stack" ])
  ; "Core__Stack", (Mutable, [ "Core_stack" ])
  ; "Core__Stack_intf", (Mutable, [ "Core_stack" ])
  ; "Base__Linked_queue", (Mutable, [ "Queue" ])
  ; "Core__Linked_queue", (Mutable, [ "Queue" ])
  ; "Core__Deque", (Mutable, [ "Core_deque" ])
  ; "Core__Deque_intf", (Mutable, [ "Core_deque" ])
  ; "Core__Fdeque", (Immutable, [ "Core_fdeque" ])
  ; "Core__Fdeque_intf", (Immutable, [ "Core_fdeque" ])
  ; "Core__Fqueue", (Immutable, [ "Core_fdeque" ])
  ; "Core__Doubly_linked", (Mutable, [ "Core_doubly_linked" ])
  ; "Core__Doubly_linked_intf", (Mutable, [ "Core_doubly_linked" ])
  ; "Core__Hash_queue", (Mutable, [ "Core_hash_queue" ])
  ; "Core__Hash_queue_intf", (Mutable, [ "Core_hash_queue" ]) ]

(* declaring unit of a uid. [Subst] copies uids verbatim, so [Item]
   survives [Map.Make], [include], [open] and aliasing.
   [Local_opaque_item] (functor params, first-class modules) names the
   using unit, not the origin: fail closed on it and the rest. *)
let uid_comp_unit : Shape.Uid.t -> string option = function
  | Shape.Uid.Item { comp_unit; _ } -> Some comp_unit
  | Shape.Uid.Compilation_unit _ | Shape.Uid.Local_opaque_item _
  | Shape.Uid.Internal | Shape.Uid.Predef _ -> None

(* Submodules a container module declares beside its own [t], whose
   types share its compilation unit and would otherwise be taken for the
   container itself: a [Doubly_linked.Elt.t] is one element, not a list,
   and a [Map.Tree.t] is a bare tree with no wrapper record around it --
   walking either as its parent would mislabel it.  Matched on the
   module component a type path is reached through, which is the only
   place a unit-level table can tell them apart. *)
let aux_type_modules =
  [ "Elt"; "Tree"; "Key"; "Comparator"; "Hashable"; "Header" ]

(* the unit a type's head constructor is declared in, unless the type is
   one of those auxiliary ones *)
let type_unit env ty =
  match Types.get_desc ty with
  | Types.Tconstr (path, _, _) ->
    begin match path with
    | Path.Pdot (Path.Pdot (_, m), _) when List.mem m aux_type_modules ->
      None
    | Path.Pdot _ | Path.Pident _ | Path.Papply _ | Path.Pextra_ty _ ->
      begin match Env.find_type path env with
      | decl -> uid_comp_unit decl.type_uid
      | exception Not_found -> None
      end
    end
  | _ -> None

(* The units [e]'s type could be catalogued under, most specific first:
   the type AS WRITTEN, then what it expands to.  Both are needed, and
   for opposite reasons: a transparent alias of another library's type
   ([Core.Map.t] = [Base.Map.t]) is only recognisable once expanded,
   while an alias to something the catalogue must NOT claim
   ([Doubly_linked.t] is an [Elt.t option ref], and a ref is nobody's
   data structure) is only recognisable before.  Whether a library hides
   a type behind its .mli then stops mattering. *)
let type_units (e : Typedtree.expression) =
  let as_written = type_unit e.exp_env e.exp_type in
  let expanded =
    type_unit e.exp_env (Ctype.expand_head e.exp_env e.exp_type)
  in
  match as_written, expanded with
  | Some a, Some b when String.equal a b -> [ a ]
  | Some a, Some b -> [ a; b ]
  | Some a, None | None, Some a -> [ a ]
  | None, None -> []

(* the catalogue entry [e]'s type is walked as, by the first of its
   units the catalogue knows.  [None] for anything else: a type from an
   unknown unit, a predefined type, a functor parameter, a function
   type. *)
let structure_ds (e : Typedtree.expression) =
  List.find_map
    (fun unit -> List.assoc_opt unit ds_of_type_unit)
    (type_units e)

(* partial application: the call leaves an arrow *)
let is_partial (e : Typedtree.expression) =
  match Types.get_desc (Ctype.expand_head e.exp_env e.exp_type) with
  | Types.Tarrow _ -> true
  | _ -> false

(* a mutable call's argument roots, each with its own catalogue name:
   every argument that is a plain ident holding one of the containers
   this module operates on, in argument order -- only an ident is safe
   to re-read post-call.  A container argument that is a bigger
   expression is skipped, not fatal (its value's own events cover it).
   Deduped by path, first occurrence kept, so an argument passed twice
   is observed once. *)
let argument_roots operates args =
  let rec collect i seen = function
    | [] -> []
    | (_, Typedtree.Omitted ()) :: rest -> collect (i + 1) seen rest
    | (_, Typedtree.Arg (a : Typedtree.expression)) :: rest ->
      begin match a.exp_desc, structure_ds a with
      | Texp_ident (path, _, _), Some ds
        when List.mem ds operates
             && not (List.exists (Path.same path) seen) ->
        (Argument i, ds) :: collect (i + 1) (path :: seen) rest
      | _ -> collect (i + 1) seen rest
      end
  in
  collect 0 [] args

(* is the application [exp] (function [func], arguments [args]) an
   event, and where are its roots?  An immutable-module call observes
   the structure it RETURNS.  A total mutable-module call observes every
   structure-typed ident argument -- post-call, so mutations are seen at
   the container ([add]'s queue, both of [transfer]'s); reads re-observe
   too, since types cannot tell [iter] from [remove] -- and the result
   as well when it is itself a structure ([create], [copy], [pop] on a
   container of containers).  Containers first, result last, one record
   each inside the call's single frame; each root is walked as the
   catalogue entry ITS OWN type resolves to, which is how popping a map
   off a queue of maps is observed as a map.  No roots: not an event. *)
let classify (exp : Typedtree.expression)
      (func : Typedtree.expression) args : (root * string) list =
  match func.exp_desc with
  | Texp_ident (_, _, vd) ->
    begin match uid_comp_unit vd.val_uid with
    | None -> []
    | Some comp_unit ->
      begin match List.assoc_opt comp_unit ds_table with
      | None -> []
      | Some (mutability, operates) ->
        let result =
          match structure_ds exp with
          | Some ds -> [ Result, ds ]
          | None -> []
        in
        begin match mutability with
        | Immutable -> result
        | Mutable ->
          if is_partial exp then []
          else argument_roots operates args @ result
        end
      end
    end
  | _ -> []

(* ---- the static type each root carries ---- *)

(* [ty] printed as the user reads it at [env]: inside
   [wrap_printing_env] so paths shorten against the caller's scope
   ([int M.t], not a fully-qualified functor application).
   [type_scheme] keeps generalized variables as ['a] where [type_expr]
   would print ['_weak1]; a variable the unit never constrained still
   prints weak, which is the honest answer. *)
let print_type env ty =
  Printtyp.wrap_printing_env ~error:false env
    (fun () -> Format.asprintf "%a" Printtyp.type_scheme ty)

(* The sibling type a functor result names its contents by -- [M.key]
   for a map [M.t], [M.elt] for a set -- fully expanded, so
   [Map.Make(String)]'s key prints [string] rather than [M.key].  Only
   a dotted head has a module to look inside; anything else (a bare
   [include Map.Make(String)], a functor parameter) fails closed and
   the caller omits the role. *)
let sibling_type env t_path name =
  match (t_path : Path.t) with
  | Pdot (parent, _) ->
    let path = Path.Pdot (parent, name) in
    begin match Env.find_type path env with
    | decl ->
      if decl.type_arity = 0
      then Some (Ctype.expand_head env (Ctype.newconstr path []))
      else None
    | exception Not_found -> None
    end
  | Pident _ | Papply _ | Pextra_ty _ -> None

(* The per-role type parameters of a root of kind [ds], keyed the way a
   reader labels them: a map has a [key] and [data], a set an [elt].
   [Map]/[Set] are functor results whose [t] hides the key/element, so
   those come from the sibling type; [Queue]/[Hashtbl] carry theirs as
   ordinary type arguments.  A role that cannot be resolved is omitted
   -- the printed type alone still describes the root. *)
let role_types env ~ds ty =
  match Types.get_desc (Ctype.expand_head env ty) with
  | Types.Tconstr (path, args, _) ->
    let sibling name =
      match sibling_type env path name with
      | Some ty -> [ (name, ty) ]
      | None -> []
    in
    begin match ds, args with
    | "Map", [ data ] -> sibling "key" @ [ ("data", data) ]
    | "Set", [] -> sibling "elt"
    | "Queue", [ elt ] -> [ ("elt", elt) ]
    | "Hashtbl", [ key; data ] -> [ ("key", key); ("data", data) ]
    (* Base and Core carry theirs as ordinary arguments, a comparator
       or hash witness trailing the ones that mean something; a hash set
       is a table of unit, so its element is the KEY position *)
    | ("Core_map" | "Core_hashtbl" | "Core_hash_queue"), (key :: data :: _)
      -> [ ("key", key); ("data", data) ]
    | ("Core_set" | "Core_hash_set" | "Core_queue" | "Core_stack"
      | "Core_deque" | "Core_fdeque" | "Core_doubly_linked" | "Stack"
      | "Dynarray"), (elt :: _) -> [ ("elt", elt) ]
    | _ -> []
    end
  | _ -> []

(* the same roles, printed for the [ty] payload *)
let type_params env ~ds ty =
  List.map
    (fun (role, t) -> (role, print_type env t))
    (role_types env ~ds ty)

(* the [ty] argument of an event: the root's type as inferred (aliases
   kept -- expansion happens only to find the head), plus the roles *)
let root_ty ~ds (e : Typedtree.expression) =
  (print_type e.exp_env e.exp_type, type_params e.exp_env ~ds e.exp_type)

(* ---- payload schemas: what the walker labels user data with ---- *)

(* Entry [i] of a schema table describes one user-data block shape.
   [labels] names its fields positionally ("" = unnamed, so the walker
   falls back to the field index); [fields] gives, per field, the entry
   describing the block that field points at, or [no_schema] when the
   type does not say.  [kind] is [kind_fixed] for a fixed-size block --
   a record, a tuple, a list cell -- and [kind_array] for an array,
   every slot of which takes the single entry in [fields].

   Variants are not described here: telling [Foo x] from [Bar x] needs
   the block tag, which the wire does not carry yet.  Neither is a
   field left as a type variable -- [ld_type] is written in the
   declaration's own parameters, not the ones at this use site. *)

type schema_entry =
  { labels : string list
  ; fields : int list
  ; kind : int }

let no_schema = -1
let kind_fixed = 0
let kind_array = 1

(* deep nesting must not turn one event into an unbounded literal *)
let max_schema_entries = 64

type schema_tbl =
  { slots : (int, schema_entry) Hashtbl.t
  ; memo : (string, int) Hashtbl.t
  ; mutable n : int }

let new_schema_tbl () =
  { slots = Hashtbl.create 8; memo = Hashtbl.create 8; n = 0 }

(* an index is handed out before the entry is filled, so a type under
   construction can already be referred to *)
let reserve tbl = let i = tbl.n in tbl.n <- i + 1; i
let fill tbl i entry = Hashtbl.replace tbl.slots i entry

let schema_entries tbl =
  List.init tbl.n (fun i ->
    match Hashtbl.find_opt tbl.slots i with
    | Some e -> e
    | None -> { labels = []; fields = []; kind = kind_fixed })

(* [describe_type env tbl ty] adds the entries describing [ty]'s blocks
   to [tbl] and returns [ty]'s own entry.  A named type is memoized --
   under its PRINTED form, so [int list] and [string list] stay
   distinct -- before its fields are described, which is what makes a
   recursive type close the loop on the entry under construction
   instead of expanding forever. *)
let rec describe_type env tbl ty =
  if tbl.n >= max_schema_entries then no_schema
  else
    let ty = Ctype.expand_head env ty in
    match Types.get_desc ty with
    | Types.Ttuple parts ->
      let i = reserve tbl in
      let labels =
        List.map (function (Some l, _) -> l | (None, _) -> "") parts
      in
      let fields = List.map (fun (_, t) -> describe_type env tbl t) parts in
      fill tbl i { labels; fields; kind = kind_fixed };
      i
    | Types.Tconstr (path, args, _) ->
      let key = print_type env ty in
      begin match Hashtbl.find_opt tbl.memo key with
      | Some i -> i
      | None ->
        let element () =
          match args with
          | [ e ] -> describe_type env tbl e
          | [] | _ :: _ :: _ -> no_schema
        in
        if Path.same path Predef.path_list then begin
          (* a cell is  hd :: tl , the tail taking this same entry *)
          let i = reserve tbl in
          Hashtbl.replace tbl.memo key i;
          let e = element () in
          fill tbl i
            { labels = [ "hd"; "tl" ]
            ; fields = [ e; i ]
            ; kind = kind_fixed };
          i
        end
        else if Path.same path Predef.path_array then begin
          let i = reserve tbl in
          Hashtbl.replace tbl.memo key i;
          let e = element () in
          fill tbl i { labels = []; fields = [ e ]; kind = kind_array };
          i
        end
        else begin
          match Env.find_type path env with
          | { Types.type_kind =
                Types.Type_record (lbls, Types.Record_regular); _ } ->
            let i = reserve tbl in
            Hashtbl.replace tbl.memo key i;
            let labels =
              List.map (fun ld -> Ident.name ld.Types.ld_id) lbls
            in
            let fields =
              List.map
                (fun ld -> describe_type env tbl ld.Types.ld_type)
                lbls
            in
            fill tbl i { labels; fields; kind = kind_fixed };
            i
          | { Types.type_kind = _; _ } -> no_schema
          | exception Not_found -> no_schema
        end
      end
    | Types.Tvar _ | Types.Tarrow _ | Types.Tobject _ | Types.Tfield _
    | Types.Tnil | Types.Tlink _ | Types.Tsubst _ | Types.Tvariant _
    | Types.Tunivar _ | Types.Tpoly _ | Types.Tpackage _
    | Types.Tfunctor _ -> no_schema

(* The DS name a value observed for its own sake travels under: not a
   container, so [Data_structure] gives it no layout and the walk is
   steered entirely by its schema. *)
let user_ds = "User"

(* The schemas a root of kind [ds] can reach: one shared table plus the
   entry each role resolves to.  A container's roles are the ones
   [type_params] labels and describe its PAYLOAD; a user-declared root
   is itself the user data, so it takes the single role [self] and the
   walk starts there.  A role the schema cannot describe is omitted,
   exactly as an unresolved role is omitted from [ty]. *)
let root_schema ~ds (e : Typedtree.expression) =
  let env = e.exp_env in
  let tbl = new_schema_tbl () in
  let roles =
    if String.equal ds user_ds then begin
      let i = describe_type env tbl e.exp_type in
      if i = no_schema then [] else [ ("self", i) ]
    end
    else
      List.filter_map
        (fun (role, t) ->
           let i = describe_type env tbl t in
           if i = no_schema then None else Some (role, i))
        (role_types env ~ds e.exp_type)
  in
  (schema_entries tbl, roles)

(* [Stdlib__Map] and friends declare library types, not the program's
   own.  Predef types ([list], [array], [int]) never reach this test --
   [uid_comp_unit] already fails closed on them, which is what keeps a
   bare [let xs = [1; 2; 3]] from becoming an event. *)
let is_stdlib_unit unit =
  let p = "Stdlib" in
  String.length unit >= String.length p
  && String.equal (String.sub unit 0 (String.length p)) p

(* [e]'s head type constructor was declared by the program itself.
   Read WITHOUT [Ctype.expand_head]: expanding follows an alias like
   [type trades = trade list] down to the predef [list] and would
   reject exactly the declarations worth observing.  A bare tuple is
   not a [Tconstr] at all, so it never qualifies either.

   A CATALOGUED container is not the program's own, whichever library
   declared it: the container path already observes it, with the call
   that built it and the roles of its contents, so observing the binding
   as well would emit the same value twice under worse metadata. *)
let is_user_declared (e : Typedtree.expression) =
  match Types.get_desc e.exp_type with
  | Types.Tconstr (path, _, _) ->
    begin match Env.find_type path e.exp_env with
    | decl ->
      begin match uid_comp_unit decl.type_uid with
      | Some unit ->
        not (is_stdlib_unit unit)
        && not (List.mem_assoc unit ds_of_type_unit)
      | None -> false
      end
    | exception Not_found -> false
    end
  | Types.Tvar _ | Types.Tarrow _ | Types.Ttuple _ | Types.Tobject _
  | Types.Tfield _ | Types.Tnil | Types.Tlink _ | Types.Tsubst _
  | Types.Tvariant _ | Types.Tunivar _ | Types.Tpoly _
  | Types.Tpackage _ | Types.Tfunctor _ -> false

(* ---- the injected observation ---- *)

(* Build and type [Vreplay.snapshot ~loc ~fn ~ds ~args ~name ~ty <root>]
   in [env].  [root] is always a plain identifier -- [__vreplay_res] or a
   mutated argument ([argument_roots] only accepts idents) -- so typing
   it in the post-call env resolves to the value in scope there.  [name]
   is the identifier the root is known by in the source ("" = none);
   [loc], [fn], [args], [name] and [ty] become literal tuples/lists of
   string and int constants in [Wire.t]'s and [root_ty]'s shapes.
   [Vreplay] is resolved by ordinary name resolution against the
   instrumented unit's load path ("+vreplay", driver/compmisc.ml). *)
let snapshot_call env ~loc ~fn ~ds ~args ~name ~ty ~schema ~root =
  let str s =
    Ast_helper.Exp.constant
      { pconst_desc = Pconst_string (s, Location.none, None)
      ; pconst_loc = Location.none }
  in
  let int n =
    Ast_helper.Exp.constant
      { pconst_desc = Pconst_integer (string_of_int n, None)
      ; pconst_loc = Location.none }
  in
  let tuple parts =
    Ast_helper.Exp.tuple (List.map (fun e -> (None, e)) parts)
  in
  let rec list_of elt = function
    | [] ->
      Ast_helper.Exp.construct
        (Location.mknoloc (Longident.Lident "[]")) None
    | x :: rest ->
      Ast_helper.Exp.construct
        (Location.mknoloc (Longident.Lident "::"))
        (Some (tuple [ elt x; list_of elt rest ]))
  in
  let arg_triple (k, l, v) = tuple [ str k; str l; str v ] in
  let ty_pair (role, t) = tuple [ str role; str t ] in
  let schema_entry e =
    tuple [ list_of str e.labels; list_of int e.fields; int e.kind ]
  in
  let schema_role (role, i) = tuple [ str role; int i ] in
  let snapshot_fn =
    Ast_helper.Exp.ident
      (Location.mknoloc
         (Longident.Ldot
            ( Location.mknoloc (Longident.Lident "Vreplay")
            , Location.mknoloc "snapshot" )))
  in
  let file, line, char_start, char_end = loc in
  let fn_kind, fn_text = fn in
  let ty_printed, ty_params = ty in
  let schema_tbl, schema_roles = schema in
  Typecore.type_expression env
    (Ast_helper.Exp.apply snapshot_fn
       [ ( Asttypes.Labelled "loc"
         , tuple [ str file; int line; int char_start; int char_end ] )
       ; (Asttypes.Labelled "fn", tuple [ str fn_kind; str fn_text ])
       ; (Asttypes.Labelled "ds",  str ds)
       ; (Asttypes.Labelled "args", list_of arg_triple args)
       ; (Asttypes.Labelled "name", str name)
       ; ( Asttypes.Labelled "ty"
         , tuple [ str ty_printed; list_of ty_pair ty_params ] )
       ; ( Asttypes.Labelled "schema"
         , tuple
             [ list_of schema_entry schema_tbl
             ; list_of schema_role schema_roles ] )
       ; (Asttypes.Nolabel, Ast_helper.Exp.ident (Location.mknoloc root)) ])

(* the identifier the post-call hook reads: the bound result, or the
   mutated argument (an ident, per [argument_roots]) *)
let root_lid args = function
  | Result -> Longident.Lident res_binder_name
  | Argument i ->
    begin match List.nth args i with
    | (_, Typedtree.Arg
           { Typedtree.exp_desc = Texp_ident (_, lid, _); _ }) -> lid.txt
    | _ -> assert false (* [argument_roots] only returns ident positions *)
    end

(* the typed expression a root's static type is read off: the whole
   application for a Result, the argument at that position otherwise *)
let root_expression (exp : Typedtree.expression) args = function
  | Result -> exp
  | Argument i ->
    begin match List.nth args i with
    | (_, Typedtree.Arg a) -> a
    | _ -> assert false (* [argument_roots] only returns [Arg] positions *)
    end

(* ---- code generation ---- *)

(* wrap [exp] (a Texp_apply) in frame markers, optionally running
   [inject_before] ahead of the call and each [inject_after] hook (in
   list order) after it, with the result bound to [res_binder_name]; a
   raising call skips everything after itself.  returns an exp_desc. *)
let instrument_call ?inject_before ~inject_after
      (exp : Typedtree.expression)
      ~(emit : Env.t -> string -> Typedtree.expression) =
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
  (* fold_right keeps list order at runtime: the first hook's seq ends
     up outermost, so it runs first *)
  let tail =
    List.fold_right
      (fun hook tail -> seq env_with_res (hook env_with_res) tail)
      inject_after tail
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
  let head =
    match inject_before with
    | None -> tail
    | Some hook -> seq exp.exp_env (hook exp.exp_env) tail
  in
  (seq exp.exp_env (emit exp.exp_env frame_open) head).exp_desc

(* rewrite each [Texp_apply] that [classify] marks as an event: the
   post-call hook hands the traversal root to [Vreplay.snapshot], which
   owns identity (the weak registry), the C walk and the sexp emit *)
let inject_mapper (emit_prim : Typedtree.value_description) =
  let super = Tast_mapper.default in
  let emit env payload = Wire.emit emit_prim env payload in

  (* the innermost enclosing [let] binder and its right-hand side, live
     while that RHS is being visited: [inject_value_binding] saves and
     restores it around each binding, so nested lets shadow correctly.
     A Result root takes the name only when its application is
     PHYSICALLY the whole RHS -- inner calls stay anonymous.  ([let*]
     bindings never pass through [value_binding]; their results stay
     anonymous.) *)
  let current_binder : (string * Typedtree.expression) option ref =
    ref None
  in
  let inject_value_binding self (vb : Typedtree.value_binding) =
    let binder =
      match vb.vb_pat.pat_desc with
      | Tpat_var (_, { txt; _ }, _) -> Some (txt, vb.vb_expr)
      | _ -> None
    in
    let vb =
      Misc.protect_refs [ Misc.R (current_binder, binder) ]
        (fun () -> super.value_binding self vb)
    in
    (* A value of the program's OWN type is worth observing for its own
       sake -- this is what makes [let p = { x = 3; y = 4 }] an event
       where nothing but container calls used to be one.  Only when the
       schema can actually describe it: an undescribable type (a
       variant, an abstract one) would dump an unlabelled block, which
       is no better than the numbering this replaces. *)
    match binder with
    | Some (name, bound) when is_user_declared bound ->
      let ((_ : schema_entry list), roles) as schema =
        root_schema ~ds:user_ds bound
      in
      begin match roles with
      | [] -> vb
      | _ :: _ ->
        (* the binding as the program WROTE it: [vb_expr] has been
           rewritten by now, and printing that would put this pass's own
           injected code on the wire as the event's source text *)
        let wire = Wire.format_binding bound in
        let ty = root_ty ~ds:user_ds bound in
        let hooks =
          [ (fun env ->
               snapshot_call env ~loc:wire.Wire.location
                 ~fn:wire.Wire.function_info ~ds:user_ds
                 ~args:wire.Wire.argument_list ~name ~ty ~schema
                 ~root:(Longident.Lident res_binder_name)) ]
        in
        { vb with
          vb_expr =
            { vb.vb_expr with
              exp_desc =
                instrument_call vb.vb_expr ~emit ~inject_after:hooks } }
      end
    | Some _ | None -> vb
  in

  let inject_expression self (exp : Typedtree.expression) =
    let recurse_down : Typedtree.expression = super.expr self exp in
    match exp.exp_desc with
    | Texp_apply (func, args) ->
      begin match classify exp func args with
      | [] -> recurse_down
      | roots ->
        let wire = Wire.format_function_call exp func args in
        let result_name =
          match !current_binder with
          | Some (name, rhs) when rhs == exp -> name
          | Some _ | None -> ""
        in
        let hooks =
          List.map
            (fun (root, ds) ->
               let name =
                 match root with
                 | Result -> result_name
                 | Argument _ ->
                   Format.asprintf "%a" Pprintast.longident
                     (root_lid args root)
               in
               let root_exp = root_expression exp args root in
               let ty = root_ty ~ds root_exp in
               let schema = root_schema ~ds root_exp in
               let root = root_lid args root in
               fun env ->
                 snapshot_call env ~loc:wire.Wire.location
                   ~fn:wire.Wire.function_info ~ds
                   ~args:wire.Wire.argument_list ~name ~ty ~schema ~root)
            roots
        in
        { exp with
          exp_desc = instrument_call recurse_down ~emit ~inject_after:hooks }
      end
    | _ -> recurse_down
  in
  { super with
    Tast_mapper.expr = inject_expression
  ; value_binding = inject_value_binding }

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
      Typedecl.transl_value_decl decl_env Location.none Wire.emit_decl
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
