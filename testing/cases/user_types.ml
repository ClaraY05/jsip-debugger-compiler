(* Values of the program's OWN types are observed for their own sake --
   no container call anywhere in this file, which used to mean no dump
   at all.  Each [let] of a user-declared type emits one event whose
   root is that value, labelled from its declaration.

   The negatives matter as much: [xs], [arr] and [pair] are a bare
   list, array and tuple, none of them declared here, so none of them
   is an event.  They are contents, not subjects -- they get drawn only
   when reached from something that IS one, as [tags] and [span] are
   below. *)

type point = { x : int; y : int }

type trade =
  { price : int
  ; tags : string array
  ; span : int * int
  }

type trades = trade list

let () =
  let p = { x = 3; y = 4 } in
  let t = { price = 101; tags = [| "buy"; "limit" |]; span = (1, 9) } in
  let ts : trades = [ t ] in
  let xs = [ 1; 2; 3 ] in
  let arr = [| 10; 20 |] in
  let pair = (1, 2) in
  ignore (p, ts, xs, arr, pair)
