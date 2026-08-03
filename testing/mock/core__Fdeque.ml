(* Stands in for Core's Fdeque (and so for Fqueue, which IS Fdeque):
   the same unit name and the same REPRESENTATION -- two ordinary lists,
   [back] holding the tail of the deque reversed. *)

type 'a t =
  { front : 'a list
  ; back : 'a list
  ; length : int
  }

let empty = { front = []; back = []; length = 0 }

let enqueue_back t x =
  { t with back = x :: t.back; length = t.length + 1 }

let enqueue_front t x =
  { t with front = x :: t.front; length = t.length + 1 }

let dequeue_front t =
  match t.front, t.back with
  | [], [] -> None
  | x :: front, _ -> Some (x, { t with front; length = t.length - 1 })
  | [], back ->
    begin match List.rev back with
    | [] -> None
    | x :: front -> Some (x, { front; back = []; length = t.length - 1 })
    end
