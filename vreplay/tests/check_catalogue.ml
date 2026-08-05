(* The catalogue round-trip check: every name the instrumentation's
   [Catalogue.table] can emit as an event's [ds] must resolve in the
   runtime library's [Data_structure.of_name].  An unmatched name is a
   silent no-op at run time -- this turns it into a red test.  Links
   compilerlibs/ocamlcommon (for the table) against vreplay.cma (for
   the catalogue); exits 1 listing any offender. *)

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
