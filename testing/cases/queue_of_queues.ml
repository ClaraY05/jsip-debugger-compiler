(* Containers of containers: [add]ing one queue into another observes
   the OUTER queue (its new cell holds an (Id _) boundary for the
   inner), and [pop] observes both the shrunken container argument and
   the structure it returns -- one record per root, all inside the
   call's single frame. *)
let () =
  let qq = Queue.create () in
  let q1 = Queue.create () in
  Queue.add q1 qq;
  ignore (Queue.pop qq)
