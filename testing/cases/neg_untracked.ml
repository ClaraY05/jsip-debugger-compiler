(* Negative: Stack is out of ds_table until the runtime catalogue has
   its layout, and list/array are predef-typed (not declared in any unit
   ds_table could list).  Empty dump.  (Hashtbl left this list when it
   got its layered layout -- see hashtbl_basic.) *)
let () =
  let s = Stack.create () in
  Stack.push 1 s;
  ignore (Stack.pop s);
  ignore (List.map succ [ 1; 2 ]);
  ignore (Array.map succ [| 1; 2 |])
