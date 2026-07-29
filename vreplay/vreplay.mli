(* Visual-replay runtime support (linked into the instrumented program). *)

(* Shape of one tracked object as returned by the C walker. *)
type field =
  | Cell of int          (* index of an internal cell within this same shape *)
  | Edge of int          (* stable id of a separately-tracked object *)
  | Ptr of nativeint     (* opaque / boundary pointer, address only *)
  | Leaf of string       (* decoded scalar *)

type cell = { addr : nativeint; tag : int; size : int; fields : field array }

(* Per-data-structure layout, keyed by module name (e.g. "Map"). *)
type ds_layout = { labels : string list; mask : int }

(* Hand-authored table of the data structures we know how to walk. *)
val ds_info : (string, ds_layout) Hashtbl.t

(* [snapshot ~loc ~fn ~ds root] assigns [root] a stable id (holding it weakly),
   walks its in-memory shape, and prints one s-expression [event] to stdout.
   No-ops when [ds] is not a known data structure or [root] is immediate. *)
val snapshot : loc:string -> fn:string -> ds:string -> 'a -> unit
