(* stdlib Stack: a {c; len} record over a list whose head is the top.
   Mutable, so every call re-observes the stack it was handed. *)
let () =
  let s = Stack.create () in
  Stack.push 1 s;
  Stack.push 2 s;
  ignore (Stack.pop s)
