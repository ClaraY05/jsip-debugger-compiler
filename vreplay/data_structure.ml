(* The catalogue of data structures visual replay knows how to walk. *)

(* Constructor ORDER is part of the C walker's contract --
   runtime/snapshot.c stores this value verbatim into each wire node. *)
type t = Map | Set

let to_string = function Map -> "Map" | Set -> "Set"

(* The DS name the instrumentation passes at each event ([ds_table] in
   typing/vreplay_instrumentation.ml -- it may list units, e.g. Hashtbl,
   that have no entry here yet; those events no-op at runtime). *)
let of_module = function
  | "Map" -> Some Map
  | "Set" -> Some Set
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
