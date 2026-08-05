(* Validates a -visual-replay dump.  Every line must be a leading run of
   {} depth markers followed by at most one event sexp; every event must
   have the wrapper fields in order (the binder is omitted for a root
   observed under no name, and must be in the event's own scope
   otherwise); every snapshot must round-trip
   through Vreplay.from_sexp/to_sexp; depth must return to 0 at EOF.
   Structure-sharing invariants, dump-global: a node id is defined once
   -- it may reappear only as an event's ROOT (a re-observation), and
   for an immutable DS only as a revisit stub (empty block/children);
   every (Id n) resolves to a node defined at or before its event;
   registry ids are dumped node ids; addresses are unique within an
   event.  Usage: check_dump <dump-file>.  Exits 1 on the first
   violation. *)

let fail line msg =
  Printf.eprintf "check_dump: line %d: %s\n" line msg;
  exit 1

(* node ids defined by all events so far *)
let defined : (int, unit) Hashtbl.t = Hashtbl.create 256

let check_snapshot lineno (s : Vreplay.t) =
  let rec collect (n : Vreplay.node) acc =
    List.fold_left (fun acc c -> collect c acc) (n :: acc) n.children
  in
  let nodes = List.rev (collect s.root_node []) in    (* root first *)
  let event_ids = Hashtbl.create 16 in
  let addrs = Hashtbl.create 16 in
  List.iter
    (fun (n : Vreplay.node) ->
      if Hashtbl.mem event_ids n.id then
        fail lineno
          (Printf.sprintf "node id %d repeats within one event" n.id);
      Hashtbl.add event_ids n.id ();
      if Hashtbl.mem addrs n.virtual_address then
        fail lineno "virtual_address repeats within one event";
      Hashtbl.add addrs n.virtual_address ();
      if Hashtbl.mem defined n.id then begin
        if n != s.root_node then
          fail lineno
            (Printf.sprintf "node id %d already defined by an earlier event"
               n.id);
        if Data_structure.is_immutable s.ds_type
           && not (n.block = [] && n.children = [])
        then
          fail lineno
            (Printf.sprintf
               "immutable root id %d re-dumped instead of a revisit stub"
               n.id)
      end)
    nodes;
  (* refs may point at this event's own cells (within-walk sharing,
     cycles), which can serialize after the referring field -- resolve
     only once the whole event is collected *)
  List.iter
    (fun (n : Vreplay.node) ->
      List.iter
        (fun ((_ : string), b) ->
          match b with
          | Vreplay.Id i ->
            if not (Hashtbl.mem defined i || Hashtbl.mem event_ids i) then
              fail lineno (Printf.sprintf "(Id %d) resolves to no node" i)
          | _ -> ())
        n.block)
    nodes;
  List.iter
    (fun (n : Vreplay.node) -> Hashtbl.replace defined n.id ())
    nodes

let () =
  let ic = open_in Sys.argv.(1) in
  let depth = ref 0 in
  let events = ref 0 in
  let lineno = ref 0 in
  (try
     while true do
       let line = input_line ic in
       incr lineno;
       let n = String.length line in
       let i = ref 0 in
       while !i < n && (line.[!i] = '{' || line.[!i] = '}') do
         depth := !depth + (if line.[!i] = '{' then 1 else -1);
         if !depth < 0 then fail !lineno "depth went negative";
         incr i
       done;
       if !i < n then begin
         let sexp =
           try Sexp.of_string (String.sub line !i (n - !i))
           with Failure m -> fail !lineno m
         in
         match sexp with
         | Sexp.List
             (Sexp.Atom "event"
              :: Sexp.List [ Sexp.Atom "id"; Sexp.Atom _ ]
              :: Sexp.List [ Sexp.Atom "loc"; Sexp.List _ ]
              :: Sexp.List
                   [ Sexp.Atom "fn"
                   ; Sexp.List [ Sexp.Atom _; Sexp.Atom _ ] ]
              :: Sexp.List [ Sexp.Atom "args"; Sexp.List args ]
              :: Sexp.List [ Sexp.Atom "registry"; Sexp.List reg ]
              :: Sexp.List [ Sexp.Atom "ty"; Sexp.List ty ]
              :: tail) ->
           (* the tail is [binder]-then-[scope]-then-[snapshot], with the
              binder omitted for a root observed under no name *)
           let binder, scope, snap =
             match tail with
             | [ Sexp.List [ Sexp.Atom "binder"; Sexp.Atom b ]
               ; Sexp.List [ Sexp.Atom "scope"; Sexp.List scope ]
               ; Sexp.List [ Sexp.Atom "snapshot"; snap ] ] ->
               (Some b, scope, snap)
             | [ Sexp.List [ Sexp.Atom "scope"; Sexp.List scope ]
               ; Sexp.List [ Sexp.Atom "snapshot"; snap ] ] ->
               (None, scope, snap)
             | _ -> fail !lineno "malformed event wrapper"
           in
           List.iter
             (function
               | Sexp.List [ Sexp.Atom _; Sexp.Atom _ ] -> ()
               | _ -> fail !lineno "malformed scope entry")
             scope;
           (* the scope an event carries is the one JUST AFTER it, so a
              binding it states is what its own name means there -- the
              invariant a missing override would break *)
           (match binder with
            | None -> ()
            | Some b ->
              let binds = function
                | Sexp.List [ Sexp.Atom _; Sexp.Atom v ] -> String.equal v b
                | _ -> false
              in
              if not (List.exists binds scope) then
                fail !lineno "event binder is not in its own scope");
           List.iter
             (function
               | Sexp.List (Sexp.Atom _ :: _ :: _) -> ()
               | _ -> fail !lineno "malformed args entry")
             args;
           List.iter
             (function
               | Sexp.List
                   (Sexp.Atom _ :: Sexp.Atom a :: ([] | [ Sexp.Atom _ ]))
                 when String.length a > 2 && a.[0] = '0' && a.[1] = 'x' ->
                 ()
               | _ -> fail !lineno "malformed registry entry")
             reg;
           (match ty with
            | [ Sexp.List [ Sexp.Atom "printed"; Sexp.Atom _ ]
              ; Sexp.List [ Sexp.Atom "params"; Sexp.List params ] ] ->
              List.iter
                (function
                  | Sexp.List [ Sexp.Atom _; Sexp.Atom _ ] -> ()
                  | _ -> fail !lineno "malformed ty param")
                params
            | _ -> fail !lineno "malformed ty field");
           let s =
             try Vreplay.from_sexp snap
             with Failure m -> fail !lineno m
           in
           if Sexp.to_string (Vreplay.to_sexp s) <> Sexp.to_string snap
           then fail !lineno "snapshot does not round-trip";
           check_snapshot !lineno s;
           (* every live registry root was dumped at its own first
              event (this event's root included, just above) *)
           List.iter
             (function
               | Sexp.List (Sexp.Atom i :: _) ->
                 (match int_of_string_opt i with
                  | Some i when Hashtbl.mem defined i -> ()
                  | Some i ->
                    fail !lineno
                      (Printf.sprintf "registry id %d has no dumped node" i)
                  | None -> fail !lineno "malformed registry id")
               | _ -> fail !lineno "malformed registry entry")
             reg;
           incr events
         | _ -> fail !lineno "not an event record"
       end
     done
   with End_of_file -> ());
  if !depth <> 0 then
    fail !lineno (Printf.sprintf "final depth %d, expected 0" !depth);
  Printf.printf "%d events, depth balanced\n" !events
