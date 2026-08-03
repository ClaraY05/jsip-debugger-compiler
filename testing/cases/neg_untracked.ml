(* Negative: list and array are predef-typed (declared in no unit
   ds_table could list) and Buffer is not a catalogued structure at all.
   Empty dump.  (Stack left this list when the catalogue got its layout
   -- see stack_basic; Hashtbl before it -- see hashtbl_basic.) *)
let () =
  ignore (List.map succ [ 1; 2 ]);
  ignore (Array.map succ [| 1; 2 |]);
  let b = Buffer.create 16 in
  Buffer.add_string b "x";
  ignore (Buffer.contents b)
