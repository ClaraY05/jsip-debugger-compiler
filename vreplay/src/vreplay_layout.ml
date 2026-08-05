(* [Data_structure.layer] flattened to the C-ready arrays the walker
   steers by.  Field ORDER of [flat_shape]/[flat_layer] is the contract
   with vreplay/src/snapshot.c; change both sides or neither.  -1
   encodes "absent" throughout: any tag, no window field, default
   interior target (one layer deeper). *)

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

let plain_layer = {
  shapes = [||];
  is_array = false;
  elements_payload = false;
  windowed = false;
  win_start = -1;
  win_start_offset = 0;
  win_length = -1;
  win_mask = -1;
  win_newest_first = false;
}

(* per-field interior target, by label; -1 = default *)
let flatten_targets targets labels =
  Array.map
    (fun label ->
       match List.assoc_opt label targets with
       | Some layer -> layer
       | None -> -1)
    labels

let flatten_shape targets (s : Data_structure.shape) =
  let labels = Array.of_list s.Data_structure.labels in
  { tag = (match s.Data_structure.tag with None -> -1 | Some t -> t)
  ; labels
  ; interior = s.Data_structure.interior
  ; payload = s.Data_structure.payload
  ; targets = flatten_targets targets labels }

(* a window's field indices: -1 where the layout named no field *)
let win_field = function None -> -1 | Some i -> i

let flatten_layer targets : Data_structure.layer -> flat_layer = function
  | Data_structure.Fixed { labels; interior; payload } ->
    let labels = Array.of_list labels in
    { plain_layer with
      shapes =
        [| { tag = -1
           ; labels
           ; interior
           ; payload
           ; targets = flatten_targets targets labels } |] }
  | Data_structure.Cases shapes ->
    { plain_layer with
      shapes = Array.of_list (List.map (flatten_shape targets) shapes) }
  | Data_structure.Array_elements { elements; window } ->
    let layer =
      { plain_layer with
        is_array = true
      ; elements_payload =
          (match elements with
           | Data_structure.Payload -> true
           | Data_structure.Interior -> false) }
    in
    begin match window with
    | None -> layer
    | Some w ->
      { layer with
        windowed = true
      ; win_start = win_field w.Data_structure.start
      ; win_start_offset = w.Data_structure.start_offset
      ; win_length = win_field w.Data_structure.length
      ; win_mask = win_field w.Data_structure.mask
      ; win_newest_first = w.Data_structure.newest_first }
    end

let flatten_schema (labels, fields, kind) =
  (Array.of_list labels, Array.of_list fields, kind)

(* Per layer AND shape, the schema entry each field's payload edge
   leads to (-1 none) -- per shape because a layer's shapes need not
   put a role in the same field; an array layer's one synthetic field
   is the role named "*". *)
let payload_edges (layers : flat_layer array) roles labelled =
  let entry_of role =
    match List.assoc_opt role roles with
    | Some entry -> entry
    | None -> -1
  in
  Array.of_list
    (List.map2
       (fun layer labels ->
          match layer.is_array with
          | true -> [| [| entry_of (try List.assoc "*" labels
                                    with Not_found -> "") |] |]
          | false ->
            Array.map
              (fun shape ->
                 Array.map
                   (fun label ->
                      match List.assoc_opt label labels with
                      | Some role -> entry_of role
                      | None -> -1)
                   shape.labels)
              layer.shapes)
       (Array.to_list layers)
       labelled)

(* a pure function of the catalogue entry, so built once per entry *)
let layers_cache : (Data_structure.t, flat_layer array) Hashtbl.t =
  Hashtbl.create 17

let layers_for ds_ty =
  match Hashtbl.find_opt layers_cache ds_ty with
  | Some layers -> layers
  | None ->
    let targets = Data_structure.interior_targets ds_ty in
    let layers =
      Array.of_list
        (List.mapi
           (fun i layer ->
              flatten_layer
                (match List.assoc_opt i targets with
                 | Some t -> t
                 | None -> [])
                layer)
           (Data_structure.layout ds_ty))
    in
    Hashtbl.add layers_cache ds_ty layers;
    layers
