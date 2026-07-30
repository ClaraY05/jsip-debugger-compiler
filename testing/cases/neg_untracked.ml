(* Negative: Hashtbl and Stack are out of ds_table until the runtime
   catalogue has their layouts, and list/array are predef-typed (not
   declared in any unit ds_table could list).  Empty dump. *)
let () =
  let h = Hashtbl.create 4 in
  Hashtbl.add h "k" 1;
  let s = Stack.create () in
  Stack.push 1 s;
  ignore (Stack.pop s);
  ignore (List.map succ [ 1; 2 ]);
  ignore (Array.map succ [| 1; 2 |])
