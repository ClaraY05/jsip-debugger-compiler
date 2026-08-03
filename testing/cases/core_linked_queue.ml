(* Base/Core Linked_queue (testing/mock/base__Linked_queue.ml) is a
   STDLIB queue wearing another module's name.  The catalogue follows
   the root's type, so these events are ds_type Queue, walked with the
   stdlib queue's layout -- the module a call went through decides
   nothing about the representation it hands back. *)
module Linked_queue = Base__Linked_queue

let () =
  let q = Linked_queue.create () in
  Linked_queue.enqueue q 1;
  Linked_queue.enqueue q 2
