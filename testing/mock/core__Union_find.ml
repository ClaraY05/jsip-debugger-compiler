(* Stands in for Core's Union_find: the same unit name and the same
   REPRESENTATION -- an INVERTED forest, whose nodes hold a pointer
   UPWARDS at their parent and nothing pointing back down.  A chain ends
   at a root record carrying the value the whole equivalence class
   shares and a rank bounding its depth.

   Both operations show up in the walk: [union] hangs the shallower
   tree under the deeper one, and finding a representative re-points
   every node it passed straight at the root, so the same forest walked
   twice is flatter the second time. *)

type 'a root =
  { mutable value : 'a
  ; mutable rank : int
  }

type 'a t = { mutable node : 'a node }

and 'a node =
  | Inner of 'a t
  | Root of 'a root

let create value = { node = Root { value; rank = 0 } }

(* the root of [t]'s tree, compressing the path walked to reach it *)
let rec representative t =
  match t.node with
  | Root _ -> t
  | Inner parent ->
    let r = representative parent in
    if r != parent then t.node <- Inner r;
    r

let get t =
  match (representative t).node with
  | Root r -> r.value
  | Inner _ -> assert false (* [representative] returns a root *)

let union t1 t2 =
  let r1 = representative t1 in
  let r2 = representative t2 in
  if r1 != r2 then
    match r1.node, r2.node with
    | Root a, Root b ->
      if a.rank < b.rank then r1.node <- Inner r2
      else begin
        r2.node <- Inner r1;
        if a.rank = b.rank then a.rank <- a.rank + 1
      end
    | Root _, Inner _ | Inner _, Root _ | Inner _, Inner _ ->
      assert false (* both are roots *)
