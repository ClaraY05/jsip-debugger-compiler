(* Stands in for Core's Deque: the same unit name and the same
   REPRESENTATION -- a ring buffer whose live range starts ONE PAST
   [front_index] (that slot is where the next front enqueue goes) and
   wraps modulo the array's own length, which is no power of two, so
   there is no mask to land on. *)

type 'a t =
  { mutable arr : 'a array
  ; mutable front_index : int
  ; mutable back_index : int
  ; mutable apparent_front_index : int
  ; mutable length : int
  ; mutable arr_length : int
  ; never_shrink : bool
  }

let none : 'a = Obj.magic 0

let create ?(capacity = 5) () =
  { arr = Array.make capacity none
  ; front_index = 0
  ; back_index = 1
  ; apparent_front_index = 0
  ; length = 0
  ; arr_length = capacity
  ; never_shrink = false
  }

let enqueue_back t x =
  t.arr.(t.back_index) <- x;
  t.back_index <- (t.back_index + 1) mod t.arr_length;
  t.length <- t.length + 1

let enqueue_front t x =
  t.arr.(t.front_index) <- x;
  t.front_index <- (t.front_index - 1 + t.arr_length) mod t.arr_length;
  t.apparent_front_index <- t.apparent_front_index - 1;
  t.length <- t.length + 1
