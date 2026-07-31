(* A call whose structure result is the immediate [Empty]: the frame is
   emitted, the record is not ([Vreplay.snapshot] skips immediates --
   there is no heap cell to identify or walk).  Readers must tolerate
   the empty frame.  Note the transition "the map became empty" is
   invisible on the wire today; if that ever matters, snapshot needs an
   immediate-root record instead of a skip. *)
module M = Map.Make (String)

let () =
  let m = M.add "only" 1 M.empty in
  ignore (M.remove "only" m)
