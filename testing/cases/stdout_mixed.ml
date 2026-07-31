(* The program's own prints go to stdout; the dump goes to the sink
   (VREPLAY_FILE here).  Neither stream may corrupt the other -- this
   dump must contain events only, no "student output". *)
let () =
  let q = Queue.create () in
  print_string "student output line\n";
  Queue.add 1 q;
  print_string "partial line without newline";
  ignore (Queue.pop q)
