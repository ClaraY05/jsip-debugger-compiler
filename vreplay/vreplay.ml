(* Visual-replay runtime support.
 *
 * Linked into the instrumented program (compiled/passed alongside the user's
 * files when [-visual-replay] is used).  Owns object identity: every tracked
 * data-structure value is assigned a stable id, held WEAKLY so tracking never
 * keeps alive something the program has dropped.  The C walker [caml_wire_traverse]
 * turns one object into a flat array of cells; we serialize the result as an
 * s-expression event for a downstream visualizer to parse. *)

(* Shape returned by the C walker.  Constructor order MUST match runtime/snapshot.c
   (Cell=0, Edge=1, Ptr=2, Leaf=3). *)
type field =
  | Cell of int          (* index of an internal cell within this same shape *)
  | Edge of int          (* stable id of a separately-tracked object *)
  | Ptr of nativeint     (* opaque / boundary pointer, address only *)
  | Leaf of string       (* decoded scalar *)

type cell = { addr : nativeint; tag : int; size : int; fields : field array }

external traverse : (Obj.t * int) array -> Obj.t -> int -> cell array
  = "caml_wire_traverse"

(* ---- per-data-structure layout: labels + a pointer bitmask over the fields
   of the structure's internal node/cell type.  Hand-authored, one entry per
   supported DS, keyed by the module the operation came from. ---- *)
type ds_layout = { labels : string list; mask : int }

let ds_info : (string, ds_layout) Hashtbl.t = Hashtbl.create 16
(*CR: replace the ds+info with a variant record type of Map, Set, etc.*)
let () =
  (* stdlib Map: internal node is  Node {l; v; d; r; h}  (Empty is the int 0).
     Structural pointers are l (bit 0) and r (bit 3). *)
  Hashtbl.replace ds_info "Map"
    { labels = [ "l"; "v"; "d"; "r"; "h" ]; mask = 0b01001 };
  (* stdlib Set: internal node is  Node {l; v; r; h}.  Pointers l (bit 0), r (bit 2). *)
  Hashtbl.replace ds_info "Set"
    { labels = [ "l"; "v"; "r"; "h" ]; mask = 0b0101 }

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
type entry = { id : Id.t; values : Obj.t Weak.t }

let registry : entry Dynarray.t = Dynarray.create ()

let weak_of (o : Obj.t) : Obj.t Weak.t =
  let w = Weak.create 1 in
  Weak.set w 0 (Some o);
  w

(* The id already assigned to [o], if any. *)
let find_id (o : Obj.t) : Id.t option =
  let n = Dynarray.length registry in
  let rec go i =
    if i >= n then None
    else
      let e = Dynarray.get registry i in
      match Weak.get e.values 0 with
      | Some v when v == o -> Some e.id
      | _ -> go (i + 1)
  in
  go 0

let register (o : Obj.t) : Id.t =
  match find_id o with
  | Some id -> id
  | None ->
    let id = Id.fresh () in
    Dynarray.add_last registry { id; values = weak_of o };
    id

(* Snapshot of the currently-live tracked objects as (value, id) pairs; also
   compacts the registry, dropping entries whose object has been collected
   (retiring their ids). *)
let live_known () =
  let live = Dynarray.create () in
  let pairs = ref [] in
  Dynarray.iter
    (fun e ->
      match Weak.get e.values 0 with
      | Some o ->
        Dynarray.add_last live e;
        pairs := (o, Id.to_int e.id) :: !pairs
      | None -> ())
    registry;
  if Dynarray.length live < Dynarray.length registry then begin
    Dynarray.clear registry;
    Dynarray.append registry live
  end;
  Array.of_list !pairs

(* ---- serialization: a flat list of nodes (adjacency list) ----
   The C walker returns a flat [cell array]; index [i] IS node [i]'s id.  We
   emit one record per node -- (id, address, tag, size, value, children) --
   where [value] holds the node's non-pointer data fields (labeled) and
   [children] is the list of ids of the nodes its structural-pointer ([Cell])
   fields point at.  Children are referenced BY ID, never nested, so a node
   can have any number of them and shared / cyclic structure is represented
   exactly once with no recursion.  Hand-rolled (no Core/sexplib dependency).

   e.g. root A with children B, C, and C with child D  ->
     (node (id 0) ... (children (1 2)))   (* A *)
     (node (id 1) ... (children ()))      (* B *)
     (node (id 2) ... (children (3)))     (* C *)
     (node (id 3) ... (children ()))      (* D *) *)

let label_at labels i =
  match List.nth_opt labels i with Some l -> l | None -> string_of_int i

(* a non-structural field -> node data ("value"); a [Cell] is a child and is
   listed by id in [children] instead. *)
let render_data buf lbl = function
  | Edge id -> Printf.bprintf buf "(%s (edge %d))" lbl id
  | Ptr p -> Printf.bprintf buf "(%s (ptr 0x%nx))" lbl p
  | Leaf s -> Printf.bprintf buf "(%s (leaf %S))" lbl s
  | Cell _ -> ()

let emit_event ~loc ~fn ~ds ~id ~labels ~cells =
  let buf = Buffer.create 256 in
  Printf.bprintf buf "(event (id %d) (loc %S) (fn %S) (ds %S) (nodes (" id loc fn ds;
  Array.iteri
    (fun node_id c ->
      Printf.bprintf buf " (node (id %d) (addr 0x%nx) (tag %d) (size %d) (value ("
        node_id c.addr c.tag c.size;
      (* value: the node's non-pointer data fields, labeled *)
      let sep = ref false in
      Array.iteri
        (fun fi fld ->
          match fld with
          | Cell _ -> ()
          | _ ->
            if !sep then Buffer.add_char buf ' ';
            sep := true;
            render_data buf (label_at labels fi) fld)
        c.fields;
      Buffer.add_string buf ")) (children (";
      (* children: ids of the nodes this node's [Cell] fields point at *)
      let sep = ref false in
      Array.iter
        (function
          | Cell child ->
            if !sep then Buffer.add_char buf ' ';
            sep := true;
            Printf.bprintf buf "%d" child
          | _ -> ())
        c.fields;
      Buffer.add_string buf ")))")
    cells;
  Buffer.add_string buf "))\n";
  print_string (Buffer.contents buf);
  flush stdout

(* ---- entry point injected at every event ---- *)
let snapshot ~loc ~fn ~ds root =
  match Hashtbl.find_opt ds_info ds with
  | None -> ()                              (* not a tracked data structure *)
  | Some { labels; mask } ->
    let r = Obj.repr root in
    if not (Obj.is_block r) then ()          (* immediates have no identity *)
    else begin
      let id = register r in
      let cells = traverse (live_known ()) r mask in
      emit_event ~loc ~fn ~ds ~id:(Id.to_int id) ~labels ~cells
    end
