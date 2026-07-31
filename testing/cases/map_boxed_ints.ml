(* Boxed leaf kinds on the wire: int32/int64/nativeint customs decode to
   their own constructors, bytes prints as String, and an UNKNOWN custom
   block (an in_channel) stays an opaque Address. *)
module M = Map.Make (String)

let () =
  ignore (M.add "i32" 42l M.empty);
  ignore (M.add "i64" 43L M.empty);
  ignore (M.add "nat" 44n M.empty);
  ignore (M.add "bytes" (Bytes.of_string "b\000b") M.empty);
  ignore (M.add "chan" stdin M.empty)
