(* Payload strings that stress the emitter's quoting: quotes,
   backslashes, newlines, tabs, braces and parens (which print bare,
   mid-sexp), a NUL and a high byte.  check_dump proves every line still
   parses back as exactly one event -- framing survives hostile user
   data. *)
module M = Map.Make (String)

let () =
  let m = M.add "quote\"and\\back" 1 M.empty in
  let m = M.add "newline\nand\ttab" 2 m in
  let m = M.add "{braces}(parens);semi" 3 m in
  ignore (M.add "nul\000and\xffhigh" 4 m)
