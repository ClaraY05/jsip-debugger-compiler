(* Stands in for Core's Hash_queue: the same unit name and the same
   REPRESENTATION -- a doubly-linked list of key/value pairs in queue
   order, plus a hash table mapping each key to the ELEMENT holding it.
   Core builds this through a functor over the key module; the shape it
   produces is what matters here, so the mock is plain. *)

module Key_value = struct
  type ('k, 'v) t =
    { key : 'k
    ; mutable value : 'v
    }
end

type ('k, 'v) t =
  { mutable num_readers : int
  ; queue : ('k, 'v) Key_value.t Core__Doubly_linked.t
  ; table :
      ( 'k
      , ('k, 'v) Key_value.t Core__Doubly_linked.Elt.t )
      Base__Hashtbl.t
  }

let create ?(size = 4) () =
  { num_readers = 0
  ; queue = Core__Doubly_linked.create ()
  ; table = Base__Hashtbl.create ~size ()
  }

let enqueue_back_exn t key value =
  let elt =
    Core__Doubly_linked.insert_last_elt t.queue { Key_value.key; value }
  in
  Base__Hashtbl.set t.table ~key ~data:elt
