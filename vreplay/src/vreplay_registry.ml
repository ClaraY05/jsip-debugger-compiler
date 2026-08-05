(* Object identity: the weak registry of tracked structures and the
   member store of already-dumped blocks.  Identity is PHYSICAL,
   resolved by scanning -- addresses move under the GC and contents
   mutate, so nothing here hashes -- and every reference is weak, so
   tracking never keeps alive what the program has dropped. *)

(* One counter numbers everything on the wire.  The C walker assigns
   interior-cell ids itself, sequentially from [next_int]; [advance]
   consumes them so no id is issued twice. *)
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

(* [name]: the latest non-empty identifier the object was observed
   under ("" until then) -- a small strong ref that dies with the
   entry *)
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

(* Member store: one chunk per first walk of an immutable structure,
   its new cells held weakly with their wire ids.  Chunks OUTLIVE
   registry entries (a dead version's blocks live on inside later
   versions), and a collected member simply vanishes -- a recycled
   address can never resurface under an old id. *)
type chunk = { values : Obj.t Weak.t; ids : int array }

let chunks : chunk Dynarray.t = Dynarray.create ()

(* The wire id [o] already carries, if some earlier event dumped it as
   an interior member.  Physical scan, like [find_entry]. *)
exception Found_member of int

let find_member_id (o : Obj.t) : int option =
  match
    Dynarray.iter
      (fun ch ->
        for i = 0 to Weak.length ch.values - 1 do
          match Weak.get ch.values i with
          | Some v when v == o -> raise (Found_member ch.ids.(i))
          | _ -> ()
        done)
      chunks
  with
  | () -> None
  | exception Found_member id -> Some id

(* Replace [d]'s contents with [keep] when the scan dropped anything.
   Both compactions below build [keep] as they go and call this. *)
let compact d ~keep =
  if Dynarray.length keep < Dynarray.length d then begin
    Dynarray.clear d;
    Dynarray.append d keep
  end

(* Track [o] under [name]; latest non-empty name wins.  Also says
   whether this is [o]'s FIRST dump.  A block first dumped as an
   interior member keeps its wire id when it becomes a tracked root:
   its one definition is already on the wire. *)
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

(* live (value, id, name) triples in insertion order; compacts the
   registry, retiring collected ids *)
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
  compact registry ~keep:live;
  Array.of_list (List.rev !trips)

(* The member table for one event: every live remembered member plus
   every live registry root except [root] -- appended only under
   [include_root], which is what collapses an immutable re-observation
   to a revisit stub.  Compacts [chunks]; order irrelevant (C sorts). *)
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
  compact chunks ~keep;
  Array.iter
    (fun (o, id, _name) -> if o != root then out := (o, id) :: !out)
    known;
  if include_root then out := (root, root_id) :: !out;
  Array.of_list !out

(* Remember a first walk's new cells: re-reach each through its
   discovery edge (cell 0 = [root]) -- coordinates stay valid where raw
   addresses would have moved -- and store them weakly under their
   sequential ids. *)
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
