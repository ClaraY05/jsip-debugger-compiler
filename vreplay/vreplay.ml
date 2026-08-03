(* Visual-replay runtime support.
 *
 * Linked into the instrumented program (compiled/passed alongside the user's
 * files when [-visual-replay] is used).  Owns object identity: every tracked
 * data-structure value is assigned a stable id, held WEAKLY so tracking
 * never keeps alive something the program has dropped.  The C walker
 * [caml_wire_traverse] (runtime/snapshot.c) BFSes one result value into a
 * tree of [node]s; we serialize it as one s-expression event for the
 * downstream visualizer to parse ([to_sexp] / [from_sexp]).
 *
 * The catalogue of walkable data structures lives in data_structure.ml;
 * the wire schema and all sexp conversion live in sexp.ml. *)

(* ---- the wire types, re-exported from sexp.ml so [Vreplay] presents the
   whole contract.  Constructor and field ORDER MUST match
   runtime/snapshot.c (see sexp.ml); the representation mapping they
   mirror is documented in sexp.mli. *)

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

(* Besides the walked root, the C call echoes [known] back as
   (id, address, name) triples -- the registry component of the event.
   Both come from the same no-allocation capture, so the registry's
   addresses match the addresses the nodes record; the names ride along
   verbatim ("" = anonymous).

   [members] is the pointer->wire-id table of every block some earlier
   event already defined: the remembered members of immutable
   structures plus the live registry roots.  The walked root itself is
   in it exactly when its re-observation should collapse to a revisit
   stub (see [live_members]).  The int pair is (the root's id, the
   first id for newly discovered cells); the result's third component
   is each new cell's discovery edge -- (parent cell index, raw field
   index), in discovery order -- which [absorb_members] uses to
   re-reach the new blocks.

   The last argument bundles everything that steers the walk -- one
   argument, so the external stays within the five the direct calling
   convention allows: the DS's layout, one flattened
   [Data_structure.layer] per entry (labels, interior mask, payload
   mask, is_array); the user-data schema table (labels, per-field
   entry, kind); and per layer the schema entry each field's payload
   edge leads to, -1 for none; and the schema entry describing the ROOT
   block itself, -1 when it has none (every container -- their roots
   are described by layer 0). *)
external traverse :
  Obj.t -> (Obj.t * int * string) array -> (Obj.t * int) array
  -> int * int
  -> (string array * int * int * bool) array
     * (string array * int array * int) array
     * int array array
     * int
  -> node * (int * nativeint * string) array * (int * int) array
  = "caml_wire_traverse"

let flatten_layer : Data_structure.layer -> string array * int * int * bool
  = function
  | Data_structure.Fixed { labels; interior; payload } ->
    (Array.of_list labels, interior, payload, false)
  | Data_structure.Array_elements -> ([||], 0, 0, true)

let flatten_schema (labels, fields, kind) =
  (Array.of_list labels, Array.of_list fields, kind)

(* Attach the roles the instrumentation resolved to the field positions
   [Data_structure.payload_roles] names, giving the walker a per-field
   lookup it can use without knowing anything about roles.  A role the
   schema could not describe is simply absent and leaves -1. *)
let payload_edges ds_ty roles =
  let width (layer : Data_structure.layer) =
    match layer with
    | Data_structure.Fixed { labels; _ } -> List.length labels
    | Data_structure.Array_elements -> 0
  in
  Array.of_list
    (List.map2
       (fun layer positions ->
          let edges = Array.make (width layer) (-1) in
          List.iter
            (fun (i, role) ->
               match List.assoc_opt role roles with
               | Some entry when i < Array.length edges -> edges.(i) <- entry
               | Some _ | None -> ())
            positions;
          edges)
       (Data_structure.layout ds_ty)
       (Data_structure.payload_roles ds_ty))

(* Single write path shared with the instrumentation's {} frame markers:
   C-side fprintf+fflush.  Going through the same primitive keeps records
   and markers ordered (REVIEW_FINDINGS.md #2). *)
external emit : string -> unit = "caml_wire_emit"

(* ---- identity: opaque stable ids ----
   One counter numbers everything on the wire: registry entries (a
   structure's id is its root's) and every interior cell a walk dumps.
   The C walker assigns the cell ids itself -- sequentially from
   [next_int] -- and [advance] consumes them afterwards, so no id is
   ever issued twice. *)
module Id : sig
  type t
  val fresh : unit -> t
  val to_int : t -> int
  val of_int : int -> t
  val next_int : unit -> int
  val advance : int -> unit
end = struct
  type t = int
  let next = ref 0
  let fresh () = incr next; !next
  let to_int id = id
  (* re-adopt an id the walker already put on the wire *)
  let of_int n = n
  (* the id the next [fresh] would return *)
  let next_int () = !next + 1
  (* consume the [k] ids the walker just assigned *)
  let advance k = next := !next + k
end

(* ---- registry: one growable array of weakly-held entries.  Identity is
   resolved by scanning with physical equality -- tracked values are heap
   blocks, so their addresses move under the GC and their contents may
   mutate; neither is a stable hash key, hence no hashing here at all.  (The
   C walker's per-call address table is fine: nothing moves during a walk
   because it never allocates.)  Entries are non-pinning; an entry whose
   object has been collected is dropped at the next [live_known], retiring
   its id. ---- *)

(* [name] is the latest non-empty identifier the object was observed
   under -- the [let] binder of a creation or a mutated argument's own
   identifier -- and "" until a named observation happens.  It is a
   strong reference, but a small one that dies with the entry. *)
type entry = { id : Id.t; mutable name : string; values : Obj.t Weak.t }

let registry : entry Dynarray.t = Dynarray.create ()

let weak_of (o : Obj.t) : Obj.t Weak.t =
  let w = Weak.create 1 in
  Weak.set w 0 (Some o);
  w

(* The entry already tracking [o], if any. *)
let find_entry (o : Obj.t) : entry option =
  let n = Dynarray.length registry in
  let rec go i =
    if i >= n then None
    else
      let e = Dynarray.get registry i in
      match Weak.get e.values 0 with
      | Some v when v == o -> Some e
      | _ -> go (i + 1)
  in
  go 0

(* ---- member store: what earlier events already dumped ----
   One chunk per first walk of an immutable structure: that walk's
   newly discovered cells (beyond the root, which the registry tracks)
   held weakly, paired with the wire ids the walker assigned.  Chunks
   OUTLIVE registry entries: a dead version's blocks usually live on
   inside later versions, so a chunk is dropped only once every slot
   has been collected (see [live_members]).  The weak slots also make
   staleness impossible: a collected member simply vanishes from the
   next table, so an address the GC recycled can never resurface under
   an old id. *)
type chunk = { values : Obj.t Weak.t; ids : int array }

let chunks : chunk Dynarray.t = Dynarray.create ()

(* The wire id [o] already carries, if some earlier event dumped it as
   an interior member.  Physical scan, like [find_entry]. *)
let find_member_id (o : Obj.t) : int option =
  let found = ref None in
  Dynarray.iter
    (fun ch ->
      for i = 0 to Weak.length ch.values - 1 do
        if !found = None then
          match Weak.get ch.values i with
          | Some v when v == o -> found := Some ch.ids.(i)
          | _ -> ()
      done)
    chunks;
  !found

(* Track [o] under [name].  Latest non-empty name wins: re-observing a
   structure under a new identifier renames its entry, so the registry
   shows what the code currently calls it; an empty name never erases a
   known one.  Also says whether this observation is [o]'s FIRST dump
   (walk in full) or a re-observation (an immutable root collapses to
   a revisit stub).  A block first dumped as an interior member --
   e.g. [remove] returning an existing subtree as the new version --
   keeps its wire id when it becomes a tracked root: identity belongs
   to the block, and its one definition is already on the wire. *)
let register (o : Obj.t) ~name : Id.t * bool =
  match find_entry o with
  | Some e ->
    if not (String.equal name "") then e.name <- name;
    (e.id, false)
  | None ->
    (match find_member_id o with
     | Some n ->
       let id = Id.of_int n in
       Dynarray.add_last registry { id; name; values = weak_of o };
       (id, false)
     | None ->
       let id = Id.fresh () in
       Dynarray.add_last registry { id; name; values = weak_of o };
       (id, true))

(* Snapshot of the currently-live tracked objects as (value, id, name)
   triples, in registry (insertion) order; also compacts the registry,
   dropping entries whose object has been collected (retiring their
   ids). *)
let live_known () =
  let live = Dynarray.create () in
  let trips = ref [] in
  Dynarray.iter
    (fun (e : entry) ->
      match Weak.get e.values 0 with
      | Some o ->
        Dynarray.add_last live e;
        trips := (o, Id.to_int e.id, e.name) :: !trips
      | None -> ())
    registry;
  if Dynarray.length live < Dynarray.length registry then begin
    Dynarray.clear registry;
    Dynarray.append registry live
  end;
  Array.of_list (List.rev !trips)

(* The member table for one event: every live remembered member plus
   every live registry root except [root] itself, which is appended
   only when [include_root] -- an immutable structure observed again,
   which the walker then collapses to a revisit stub.  (Leaving the
   root out otherwise is what lets a fresh walk, and every mutable
   re-walk, actually walk.)  Also compacts [chunks], dropping the
   fully-dead ones.  Order is irrelevant: the C side sorts. *)
let live_members ~known ~root ~include_root ~root_id =
  let out = ref [] in
  let keep = Dynarray.create () in
  Dynarray.iter
    (fun ch ->
      let alive = ref false in
      for i = 0 to Weak.length ch.values - 1 do
        match Weak.get ch.values i with
        | Some v ->
          alive := true;
          out := (v, ch.ids.(i)) :: !out
        | None -> ()
      done;
      if !alive then Dynarray.add_last keep ch)
    chunks;
  if Dynarray.length keep < Dynarray.length chunks then begin
    Dynarray.clear chunks;
    Dynarray.append chunks keep
  end;
  Array.iter
    (fun (o, id, _name) -> if o != root then out := (o, id) :: !out)
    known;
  if include_root then out := (root, root_id) :: !out;
  Array.of_list !out

(* Remember a first walk's new cells: re-reach each one through its
   discovery edge (cell 0 is [root]; [paths.(j)] locates cell [j + 1]
   as a raw field of an earlier cell -- coordinates stay valid where
   raw addresses would have been moved by the walk's own allocation)
   and store them weakly with their sequential ids. *)
let absorb_members ~root ~paths ~first_id =
  let k = Array.length paths in
  if k > 0 then begin
    let cells = Array.make (k + 1) root in
    Array.iteri
      (fun j (parent, field) ->
        cells.(j + 1) <- Obj.field cells.(parent) field)
      paths;
    let values = Weak.create k in
    for j = 0 to k - 1 do Weak.set values j (Some cells.(j + 1)) done;
    Dynarray.add_last chunks
      { values; ids = Array.init k (fun j -> first_id + j) }
  end

(* One event, one line: call metadata, the live registry, the root's
   static type, then the [to_sexp] payload.  The {} depth markers around
   the line belong to the instrumentation, the terminating newline to
   us. *)
let emit_event ~loc ~fn ~args ~id ~registry ~ty snap =
  let line =
    Sexp.List
      [ Sexp.Atom "event"
      ; Sexp.List [ Sexp.Atom "id"; Sexp.Atom (string_of_int id) ]
      ; Sexp.List [ Sexp.Atom "loc"; Sexp.sexp_of_loc loc ]
      ; Sexp.List [ Sexp.Atom "fn"; Sexp.sexp_of_fn fn ]
      ; Sexp.List [ Sexp.Atom "args"; Sexp.sexp_of_args args ]
      ; Sexp.List [ Sexp.Atom "registry"; Sexp.sexp_of_registry registry ]
      ; Sexp.List [ Sexp.Atom "ty"; Sexp.sexp_of_ty ty ]
      ; Sexp.List [ Sexp.Atom "snapshot"; to_sexp snap ] ]
  in
  emit (Sexp.to_string line ^ "\n")

(* ---- entry point injected at every event ---- *)
let snapshot ~loc ~fn ~ds ~args ~name ~ty ~schema root =
  match Data_structure.of_module ds with
  | None -> ()                              (* not a tracked data structure *)
  | Some ds_ty ->
    let r = Obj.repr root in
    if not (Obj.is_block r) then ()          (* immediates have no identity *)
    else begin
      let layers =
        Array.of_list (List.map flatten_layer (Data_structure.layout ds_ty))
      in
      let schema_entries, schema_roles = schema in
      let schemas =
        Array.of_list (List.map flatten_schema schema_entries)
      in
      let edges = payload_edges ds_ty schema_roles in
      (* a user-declared root IS user data: it starts in schema mode
         instead of at a layer *)
      let root_entry =
        match List.assoc_opt "self" schema_roles with
        | Some entry -> entry
        | None -> -1
      in
      let immutable = Data_structure.is_immutable ds_ty in
      let id, fresh = register r ~name in
      let root_id = Id.to_int id in
      let known = live_known () in
      let members =
        live_members ~known ~root:r
          ~include_root:(immutable && not fresh) ~root_id
      in
      let next_id = Id.next_int () in
      let root_node, registry, paths =
        traverse r known members (root_id, next_id)
          (layers, schemas, edges, root_entry)
      in
      (* the walker consumed one id per newly dumped cell *)
      Id.advance (Array.length paths);
      (* mutable structures are re-walked in full every event, so their
         cells' ids are never remembered *)
      if immutable && fresh then
        absorb_members ~root:r ~paths ~first_id:next_id;
      emit_event ~loc ~fn ~args ~id:root_id ~registry ~ty
        { ds_type = ds_ty; root_node }
    end
