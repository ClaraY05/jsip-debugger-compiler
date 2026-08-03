(* The catalogue of data structures visual replay knows how to walk. *)

type t = Map | Set | Queue | Hashtbl

let to_string = function
  | Map -> "Map"
  | Set -> "Set"
  | Queue -> "Queue"
  | Hashtbl -> "Hashtbl"

(* The DS name the instrumentation passes at each event ([ds_table] in
   typing/vreplay_instrumentation.ml -- it may list units that have no
   entry here yet; those events no-op at runtime). *)
let of_module = function
  | "Map" -> Some Map
  | "Set" -> Some Set
  | "Queue" -> Some Queue
  | "Hashtbl" -> Some Hashtbl
  | _ -> None

(* Map and Set values never change after creation (operations build new
   versions that share subtrees), so their dumped blocks keep meaning
   across events: the runtime remembers them weakly and later walks
   stop at them with [Id] references.  Queue and Hashtbl mutate in
   place and are re-walked in full at every event instead. *)
let is_immutable = function
  | Map | Set -> true
  | Queue | Hashtbl -> false

type layer =
  | Fixed of
      { labels : string list
      ; interior : int
      ; payload : int
      }
  | Array_elements

(* Bit i of a mask covers field i of the node the layer describes. *)
let layout = function
  (* stdlib Map: every internal node is  Node {l; v; d; r; h}  (Empty is
     the int 0), and l/r lead to nodes of the same shape -- one layer,
     repeating.  The AVL height [h] is bookkeeping. *)
  | Map ->
    [ Fixed
        { labels = [ "l"; "v"; "d"; "r"; "h" ]
        ; interior = 0b01001 (* l, r *)
        ; payload = 0b00110 (* v, d *)
        } ]
  (* stdlib Set: Node {l; v; r; h}. *)
  | Set ->
    [ Fixed
        { labels = [ "l"; "v"; "r"; "h" ]
        ; interior = 0b0101 (* l, r *)
        ; payload = 0b0010 (* v *)
        } ]
  (* stdlib Queue: the root is  {length; first; last}  and each cell is
     Cons {content; next}  (Nil is the int 0), chained by [next] -- the
     cell layer repeats.  [last] is deliberately dropped: it is
     bookkeeping (the O(1) append pointer), and walking it would
     discover the tail cell as a direct child of the root before the
     chain reaches it, garbling the chain shape.  Cell labels stay the
     numeric "0"/"1" the wire has always used for cells. *)
  | Queue ->
    [ Fixed
        { labels = [ "length"; "first"; "last" ]
        ; interior = 0b010 (* first *)
        ; payload = 0b001 (* length *)
        }
    ; Fixed
        { labels = [ "0"; "1" ]
        ; interior = 0b10 (* next *)
        ; payload = 0b01 (* content *)
        } ]
  (* stdlib Hashtbl: the root is  {size; data; seed; initial_size},
     [data] is the bucket array, and each bucket is a
     Cons {key; data; next}  chain (Empty is the int 0).  Three layers:
     record -> array -> chain (repeating).  [seed] and [initial_size]
     are bookkeeping. *)
  | Hashtbl ->
    [ Fixed
        { labels = [ "size"; "data"; "seed"; "initial_size" ]
        ; interior = 0b0010 (* data *)
        ; payload = 0b0001 (* size *)
        }
    ; Array_elements
    ; Fixed
        { labels = [ "key"; "data"; "next" ]
        ; interior = 0b100 (* next *)
        ; payload = 0b011 (* key, data *)
        } ]

(* Positions must agree with [layout]'s payload masks above: a role
   names a field the mask already keeps, so the schema for that role's
   type describes exactly the block that field points at. *)
let payload_roles = function
  | Map -> [ [ (1, "key"); (2, "data") ] ]
  | Set -> [ [ (1, "elt") ] ]
  (* the root's [length] is a count, not user data *)
  | Queue -> [ []; [ (0, "elt") ] ]
  (* likewise the root's [size]; the bucket array has no payload *)
  | Hashtbl -> [ []; []; [ (0, "key"); (1, "data") ] ]
