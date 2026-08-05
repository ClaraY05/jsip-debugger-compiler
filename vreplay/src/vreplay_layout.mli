(* [Data_structure.layer] flattened to the C-ready arrays the walker
   steers by.  [flat_shape]/[flat_layer] are TRANSPARENT on purpose:
   the walker reads them positionally, so field ORDER is the contract
   with vreplay/src/snapshot.c -- change both sides or neither.  -1
   encodes "absent" throughout. *)

type flat_shape = {
  tag : int;
  labels : string array;
  interior : int;
  payload : int;
  targets : int array;
}

type flat_layer = {
  shapes : flat_shape array;
  is_array : bool;
  elements_payload : bool;
  windowed : bool;
  win_start : int;
  win_start_offset : int;
  win_length : int;
  win_mask : int;
  win_newest_first : bool;
}

(* the flattened layout of a catalogue entry, cached (pure per entry) *)
val layers_for : Data_structure.t -> flat_layer array

(* a schema entry (labels, per-field entry, kind), lists to arrays *)
val flatten_schema :
  string list * int list * int -> string array * int array * int

(* Per layer AND shape, the schema entry each field's payload edge
   leads to (-1 none).  [roles] maps role name -> schema entry;
   [labelled] is [Data_structure.payload_roles] for the entry. *)
val payload_edges :
  flat_layer array -> (string * int) list -> (string * string) list list
  -> int array array array
