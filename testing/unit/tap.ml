(* Tiny shared check-and-report helper for testing/unit/: TAP-ish
   "ok"/"not ok" lines, nonzero exit if any expectation failed.  Kept
   dependency-free -- the compiler build has no test framework. *)

let failed = ref 0

let check name cond =
  if cond then print_string ("ok - " ^ name ^ "\n")
  else begin
    incr failed;
    print_string ("not ok - " ^ name ^ "\n")
  end

(* [check_eq name to_string actual expected] *)
let check_eq name to_string actual expected =
  if actual = expected then print_string ("ok - " ^ name ^ "\n")
  else begin
    incr failed;
    Printf.printf "not ok - %s\n    expected: %s\n    actual:   %s\n"
      name (to_string expected) (to_string actual)
  end

let finish () =
  if !failed = 0 then exit 0
  else begin
    Printf.printf "%d check(s) FAILED\n" !failed;
    exit 1
  end
