(* Base/Core Stack (testing/mock/base__Stack.ml): a preallocated array
   holding the stack bottom-first.  The window walks it backwards, so
   the wire reads top-first the way a list-backed stack does. *)
module Stack = Base__Stack

let () =
  let s = Stack.create ~capacity:4 () in
  Stack.push s 1;
  Stack.push s 2;
  Stack.push s 3;
  ignore (Stack.pop s)
