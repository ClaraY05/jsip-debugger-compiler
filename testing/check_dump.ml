(* Validates a -visual-replay dump.  Every line must be a leading run of
   {} depth markers followed by at most one event sexp; every event must
   have the six wrapper fields in order; every snapshot must round-trip
   through Vreplay.from_sexp/to_sexp; depth must return to 0 at EOF.
   Usage: check_dump <dump-file>.  Exits 1 on the first violation. *)

let fail line msg =
  Printf.eprintf "check_dump: line %d: %s\n" line msg;
  exit 1

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
             [ Sexp.Atom "event"
             ; Sexp.List [ Sexp.Atom "id"; Sexp.Atom _ ]
             ; Sexp.List [ Sexp.Atom "loc"; Sexp.Atom _ ]
             ; Sexp.List [ Sexp.Atom "fn"; Sexp.Atom _ ]
             ; Sexp.List [ Sexp.Atom "args"; Sexp.List args ]
             ; Sexp.List [ Sexp.Atom "registry"; Sexp.List reg ]
             ; Sexp.List [ Sexp.Atom "snapshot"; snap ] ] ->
           List.iter
             (function
               | Sexp.List [ Sexp.Atom _; Sexp.Atom _ ] -> ()
               | _ -> fail !lineno "malformed args entry")
             args;
           List.iter
             (function
               | Sexp.List [ Sexp.Atom _; Sexp.Atom a ]
                 when String.length a > 2 && a.[0] = '0' && a.[1] = 'x' ->
                 ()
               | _ -> fail !lineno "malformed registry entry")
             reg;
           let s =
             try Vreplay.from_sexp snap
             with Failure m -> fail !lineno m
           in
           if Sexp.to_string (Vreplay.to_sexp s) <> Sexp.to_string snap
           then fail !lineno "snapshot does not round-trip";
           incr events
         | _ -> fail !lineno "not an event record"
       end
     done
   with End_of_file -> ());
  if !depth <> 0 then
    fail !lineno (Printf.sprintf "final depth %d, expected 0" !depth);
  Printf.printf "%d events, depth balanced\n" !events
