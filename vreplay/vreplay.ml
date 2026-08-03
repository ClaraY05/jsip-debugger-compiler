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

type node = Sexp.node = {
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
   verbatim ("" = anonymous).  The third argument is the DS's layout, one
   flattened [Data_structure.layer] per entry:
   (labels, interior mask, payload mask, is_array). *)
external traverse :
  Obj.t -> (Obj.t * int * string) array
  -> (string array * int * int * bool) array
  -> node * (int * nativeint * string) array
  = "caml_wire_traverse"

let flatten_layer : Data_structure.layer -> string array * int * int * bool
  = function
  | Data_structure.Fixed { labels; interior; payload } ->
    (Array.of_list labels, interior, payload, false)
  | Data_structure.Array_elements -> ([||], 0, 0, true)

(* Single write path shared with the instrumentation's {} frame markers:
   C-side fprintf+fflush.  Going through the same primitive keeps records
   and markers ordered (REVIEW_FINDINGS.md #2). *)
external emit : string -> unit = "caml_wire_emit"

(* ---- identity: opaque stable ids ---- *)
module Id : sig
  type t
  val fresh : unit -> t
  val to_int : t -> int
end = struct
  type t = int
  let next = ref 0
  let fresh () = incr next; !next
  let to_int id = id
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

(* Track [o] under [name].  Latest non-empty name wins: re-observing a
   structure under a new identifier renames its entry, so the registry
   shows what the code currently calls it; an empty name never erases a
   known one. *)
let register (o : Obj.t) ~name : Id.t =
  match find_entry o with
  | Some e ->
    if not (String.equal name "") then e.name <- name;
    e.id
  | None ->
    let id = Id.fresh () in
    Dynarray.add_last registry { id; name; values = weak_of o };
    id

(* Snapshot of the currently-live tracked objects as (value, id, name)
   triples, in registry (insertion) order; also compacts the registry,
   dropping entries whose object has been collected (retiring their
   ids). *)
let live_known () =
  let live = Dynarray.create () in
  let trips = ref [] in
  Dynarray.iter
    (fun e ->
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
let snapshot ~loc ~fn ~ds ~args ~name ~ty root =
  match Data_structure.of_module ds with
  | None -> ()                              (* not a tracked data structure *)
  | Some ds_ty ->
    let r = Obj.repr root in
    if not (Obj.is_block r) then ()          (* immediates have no identity *)
    else begin
      let layers =
        Array.of_list (List.map flatten_layer (Data_structure.layout ds_ty))
      in
      let id = register r ~name in
      let root_node, registry = traverse r (live_known ()) layers in
      emit_event ~loc ~fn ~args ~id:(Id.to_int id) ~registry ~ty
        { ds_type = ds_ty; root_node }
    end
