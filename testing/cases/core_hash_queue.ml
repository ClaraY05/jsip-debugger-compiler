(* Core Hash_queue (testing/mock/core__Hash_queue.ml): a doubly-linked
   list of key/value pairs in queue order, indexed by a hash table that
   points AT those same elements.  The table is bookkeeping -- walking
   it would dump every pair a second time -- so what reaches the wire is
   the queue, each element stepping down to its labelled pair while the
   chain stays on the element layer. *)
module Hash_queue = Core__Hash_queue

let () =
  let q = Hash_queue.create ~size:4 () in
  Hash_queue.enqueue_back_exn q "a" 1;
  Hash_queue.enqueue_back_exn q "b" 2;
  Hash_queue.enqueue_back_exn q "c" 3
