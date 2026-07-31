(* Not a unit test: run_unit_tests.sh compiles this one WITH
   -visual-replay to pin the known frame bug ("bug 5", testing/README.md):
   an instrumented call that raises never emits its closing "}".  Here
   [M.find] (never an event -- its result is not a structure) raises
   inside the argument list of the instrumented [M.add], after [M.add]'s
   frame opened; the program catches the exception and exits cleanly,
   leaving the dump as exactly one dangling "{".

   The runner asserts that dump verbatim.  When frames become
   exception-safe, this expectation should flip to a balanced dump. *)

module M = Map.Make (String)

let () =
  match M.add "k" (M.find "missing" M.empty) M.empty with
  | _ -> print_string "unreachable\n"
  | exception Not_found -> print_string "caught\n"
