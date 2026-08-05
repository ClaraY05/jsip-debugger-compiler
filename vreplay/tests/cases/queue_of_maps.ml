(* A tracked structure stored inside another tracked structure: the
   queue cell's content is a registry boundary, so it surfaces as an
   (Id _) indexing the same event's registry (which maps it to its
   current address) instead of being walked again. *)
module M = Map.Make (String)

let () =
  let m = M.add "k" 1 M.empty in
  let q = Queue.create () in
  Queue.add m q
