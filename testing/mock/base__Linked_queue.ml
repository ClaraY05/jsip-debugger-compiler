(* Stands in for Base's Linked_queue, whose [t] IS a [Stdlib.Queue.t].
   Nothing here has a representation of its own: the point of the mock
   is that the catalogue entry follows the ROOT'S TYPE (a stdlib queue,
   walked with the stdlib queue's layout) and not the module the call
   went through. *)

type 'a t = 'a Queue.t

let create () : _ t = Queue.create ()
let enqueue t x = Queue.add x t
