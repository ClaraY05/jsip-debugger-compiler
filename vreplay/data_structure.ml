(* The catalogue of data structures visual replay knows how to walk. *)

(* Constructor ORDER is part of the C walker's contract --
   runtime/snapshot.c stores this value verbatim into each wire node. *)
type t = Map | Set | Queue

let to_string = function Map -> "Map" | Set -> "Set" | Queue -> "Queue"

(* The DS name the instrumentation passes at each event ([ds_table] in
   typing/vreplay_instrumentation.ml -- it may list units that have no
   entry here yet; those events no-op at runtime). *)
let of_module = function
  | "Map" -> Some Map
  | "Set" -> Some Set
  | "Queue" -> Some Queue
  | _ -> None

(* Per-type layout: field labels of the DS's internal node, plus a bitmask
   of the fields that carry meaningful information -- the child pointers
   and the key/value positions.  Unmasked fields (bookkeeping, e.g. the
   AVL height [h]) never reach the wire. *)
type layout = { labels : string list; mask : int }

let layout = function
  (* stdlib Map: internal node is  Node {l; v; d; r; h}  (Empty is the
     int 0).  Meaningful: l, v (key), d (data), r. *)
  | Map -> { labels = [ "l"; "v"; "d"; "r"; "h" ]; mask = 0b01111 }
  (* stdlib Set: internal node is  Node {l; v; r; h}. *)
  | Set -> { labels = [ "l"; "v"; "r"; "h" ]; mask = 0b0111 }
  (* stdlib Queue: the root is  {length; first; last}  and each cell is
     Cons {content; next}  (Nil is the int 0).  One mask serves both
     shapes: bits 0-1 keep length+first on the root and content+next on
     every cell.  [last] is deliberately dropped -- it is bookkeeping
     (the O(1) append pointer), and walking it would discover the tail
     cell as a direct child of the root before the chain reaches it,
     garbling the chain shape.  Cells (size 2 <> 3 labels) get numeric
     field labels: 0 = content, 1 = next. *)
  | Queue -> { labels = [ "length"; "first"; "last" ]; mask = 0b011 }
