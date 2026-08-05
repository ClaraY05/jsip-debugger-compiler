(* Every name the instrumentation can emit as an event's [ds] must
   resolve in [Data_structure.of_name] -- an unmatched name is a silent
   runtime no-op; this makes it a red test.  Exits 1 listing offenders. *)

let () =
  let names = Vreplay_instrumentation.catalogue_names in
  let bad =
    List.filter (fun n -> Data_structure.of_name n = None) names
  in
  match bad with
  | [] ->
    Printf.printf "%d catalogue names resolve" (List.length names)
  | _ :: _ ->
    List.iter
      (Printf.eprintf "catalogue name %S has no Data_structure entry\n")
      bad;
    exit 1
