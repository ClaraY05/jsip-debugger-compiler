(* Visual-replay runtime support: the facade the injected code targets,
 * linked into instrumented programs (never the compiler).  Owns the
 * externals and per-event orchestration; identity lives in
 * vreplay_registry.ml, layout flattening in vreplay_layout.ml, the
 * catalogue in data_structure.ml, the wire schema in sexp.ml. *)

(* re-exported from sexp.ml so [Vreplay] presents the whole contract;
   constructor and field ORDER must match vreplay/src/snapshot.c *)

type block = Sexp.block =
  | Int of int
  | Float of float
  | String of string
  | Int32 of int32
  | Int64 of int64
  | Nativeint of nativeint
  | Float_array of float list
  | Address of nativeint
  | Id of int
  | Child

type node = Sexp.node = {
  id : int;
  virtual_address : nativeint;
  block : (string * block) list;
  children : node list;
}

type t = Sexp.snapshot = {
  ds_type : Data_structure.t;
  root_node : node;
}

let to_sexp = Sexp.to_sexp
let from_sexp = Sexp.from_sexp

(* root -> known (echoed back with walk-time addresses) -> members
   (pointer -> wire id; contains the root exactly when it should
   collapse to a revisit stub) -> (root id, first fresh id) -> walk
   steering bundled as one argument (direct calling convention allows
   five).  The result's paths component feeds [absorb_members]. *)
external traverse :
  Obj.t -> (Obj.t * int * string) array -> (Obj.t * int) array
  -> int * int
  -> Vreplay_layout.flat_layer array
     * (string array * int array * int) array
     * int array array array
     * int
  -> node * (int * nativeint * string) array * (int * int) array
  = "caml_wire_traverse"

(* the single write path, shared with the {} frame markers so records
   and markers stay ordered (vreplay/src/wire_sink.c) *)
external emit : string -> unit = "caml_wire_emit"

(* Shadow of the registry as the previous event stated it, id ->
   (address, name), so each event serializes only what changed.  The
   full echo was 90% of a real dump's bytes and most of the slowdown an
   instrumented program pays, re-stating entries that change less than
   once per event: an address only moves when the GC moves the block,
   and tracked roots settle into the major heap (a whole exchange run
   measured 0.8 upserts per event across a thousand live entries).  The
   compare runs on the triples the walker captured during its
   no-allocation walk, so an upsert's address is the walk-time address,
   exactly as the full echo's was. *)
let shadow : (int, nativeint * string) Hashtbl.t = Hashtbl.create 64

let registry_delta registry =
  let upserts = ref [] in
  Array.iter
    (fun ((id, addr, name) as trip) ->
      match Hashtbl.find_opt shadow id with
      | Some (a, n) when a = addr && String.equal n name -> ()
      | _ ->
        Hashtbl.replace shadow id (addr, name);
        upserts := trip :: !upserts)
    registry;
  (* after the pass above the shadow is a superset of the live
     registry, so they differ exactly when something was collected --
     only then is the sweep for dropped ids paid *)
  let drops =
    if Hashtbl.length shadow = Array.length registry then []
    else begin
      let live = Hashtbl.create (Array.length registry) in
      Array.iter (fun (id, _, _) -> Hashtbl.replace live id ()) registry;
      let dead = ref [] in
      Hashtbl.iter
        (fun id (_ : nativeint * string) ->
          if not (Hashtbl.mem live id) then dead := id :: !dead)
        shadow;
      List.iter (Hashtbl.remove shadow) !dead;
      List.sort Int.compare !dead
    end
  in
  Sexp.sexp_of_registry_delta
    ~upserts:(Array.of_list (List.rev !upserts))
    ~drops

(* one event, one line; the {} markers around it belong to the
   instrumentation, the terminating newline to us *)
let emit_event ~loc ~fn ~args ~id ~registry ~binder ~scope ~ty snap =
  (* an unnamed root leaves the binder field out, as an anonymous
     registry entry leaves out its name *)
  let binder_field =
    if String.equal binder "" then []
    else [ Sexp.List [ Sexp.Atom "binder"; Sexp.Atom binder ] ]
  in
  let line =
    Sexp.List
      ([ Sexp.Atom "event"
       ; Sexp.List [ Sexp.Atom "id"; Sexp.Atom (string_of_int id) ]
       ; Sexp.List [ Sexp.Atom "loc"; Sexp.sexp_of_loc loc ]
       ; Sexp.List [ Sexp.Atom "fn"; Sexp.sexp_of_fn fn ]
       ; Sexp.List [ Sexp.Atom "args"; Sexp.sexp_of_args args ]
       ; Sexp.List
           [ Sexp.Atom "registry_delta"; registry_delta registry ]
       ; Sexp.List [ Sexp.Atom "ty"; Sexp.sexp_of_ty ty ] ]
       @ binder_field
       @ [ Sexp.List [ Sexp.Atom "scope"; Sexp.sexp_of_scope scope ]
         ; Sexp.List [ Sexp.Atom "snapshot"; to_sexp snap ] ])
  in
  emit (Sexp.to_string_line line)

(* ---- entry point injected at every event ---- *)
let snapshot ~loc ~fn ~ds ~args ~name ~binder ~scope ~ty ~schema root =
  match Data_structure.of_name ds with
  | None -> ()                              (* not a tracked data structure *)
  | Some ds_ty ->
    let r = Obj.repr root in
    if not (Obj.is_block r) then ()          (* immediates have no identity *)
    else begin
      let layers = Vreplay_layout.layers_for ds_ty in
      let schema_entries, schema_roles = schema in
      let schemas =
        Array.of_list (List.map Vreplay_layout.flatten_schema schema_entries)
      in
      let edges =
        Vreplay_layout.payload_edges layers schema_roles
          (Data_structure.payload_roles ds_ty)
      in
      (* a user-declared root IS user data: it starts in schema mode
         instead of at a layer *)
      let root_entry =
        match List.assoc_opt "self" schema_roles with
        | Some entry -> entry
        | None -> -1
      in
      let immutable = Data_structure.is_immutable ds_ty in
      let id, fresh = Vreplay_registry.register r ~name in
      let root_id = Vreplay_registry.Id.to_int id in
      let known = Vreplay_registry.live_known () in
      let members =
        Vreplay_registry.live_members ~known ~root:r
          ~include_root:(immutable && not fresh) ~root_id
      in
      let next_id = Vreplay_registry.Id.next_int () in
      let root_node, registry, paths =
        traverse r known members (root_id, next_id)
          (layers, schemas, edges, root_entry)
      in
      (* the walker consumed one id per newly dumped cell *)
      Vreplay_registry.Id.advance (Array.length paths);
      (* mutable structures are re-walked in full every event, so their
         cells' ids are never remembered *)
      if immutable && fresh then
        Vreplay_registry.absorb_members ~root:r ~paths ~first_id:next_id;
      emit_event ~loc ~fn ~args ~id:root_id ~registry ~binder ~scope ~ty
        { ds_type = ds_ty; root_node }
    end
