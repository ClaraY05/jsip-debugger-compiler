(* Hashtbl: record root -> bucket array -> Cons chains -- three layers,
   the chain layer repeating along [next]; key/data are payload.  Every
   mutating call roots at the table argument; [create] at the result. *)
let () =
  let tbl = Hashtbl.create 4 in
  Hashtbl.add tbl "a" 1;
  Hashtbl.add tbl "b" 2;
  Hashtbl.replace tbl "a" 10;
  ignore (Hashtbl.find tbl "a");
  Hashtbl.remove tbl "b"
