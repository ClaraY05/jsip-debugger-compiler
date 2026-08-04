(* The catalogue of data structures visual replay knows how to walk. *)

type t =
  | Map
  | Set
  | Queue
  | Hashtbl
  | Stack
  | Dynarray
  | Core_map
  | Core_set
  | Core_hashtbl
  | Core_hash_set
  | Core_queue
  | Core_stack
  | Core_deque
  | Core_fdeque
  | Core_doubly_linked
  | Core_hash_queue
  | User

let to_string = function
  | Map -> "Map"
  | Set -> "Set"
  | Queue -> "Queue"
  | Hashtbl -> "Hashtbl"
  | Stack -> "Stack"
  | Dynarray -> "Dynarray"
  | Core_map -> "Core_map"
  | Core_set -> "Core_set"
  | Core_hashtbl -> "Core_hashtbl"
  | Core_hash_set -> "Core_hash_set"
  | Core_queue -> "Core_queue"
  | Core_stack -> "Core_stack"
  | Core_deque -> "Core_deque"
  | Core_fdeque -> "Core_fdeque"
  | Core_doubly_linked -> "Core_doubly_linked"
  | Core_hash_queue -> "Core_hash_queue"
  | User -> "User"

(* Every entry, so that [of_name] is the exact inverse of [to_string]
   rather than a second spelling of the same seventeen names.  Adding a
   constructor makes [to_string] fail to compile; add it here too. *)
let all =
  [ Map; Set; Queue; Hashtbl; Stack; Dynarray; Core_map; Core_set;
    Core_hashtbl; Core_hash_set; Core_queue; Core_stack; Core_deque;
    Core_fdeque; Core_doubly_linked; Core_hash_queue; User ]

(* The catalogue name the instrumentation passes at each event
   ([ds_table] in typing/vreplay_instrumentation.ml -- it may name
   entries that have none here yet; those events no-op at runtime). *)
let of_name name =
  List.find_opt (fun t -> String.equal (to_string t) name) all

(* Map and Set values never change after creation (operations build new
   versions that share subtrees), so their dumped blocks keep meaning
   across events: the runtime remembers them weakly and later walks
   stop at them with [Id] references.  The mutable ones are re-walked in
   full at every event instead.  Base's immutable structures share their
   spines exactly as the stdlib's do; its buffer-backed containers
   mutate in place, and so does a doubly-linked list. *)
let is_immutable = function
  | Map | Set | Core_map | Core_set | Core_fdeque -> true
  | Queue | Hashtbl | Stack | Dynarray | Core_hashtbl | Core_hash_set
  | Core_queue | Core_stack | Core_deque | Core_doubly_linked
  | Core_hash_queue | User -> false

type shape =
  { tag : int option
  ; labels : string list
  ; interior : int
  ; payload : int
  }

type elements =
  | Interior
  | Payload

type window =
  { start : int option
  ; start_offset : int
  ; length : int option
  ; mask : int option
  ; newest_first : bool
  }

let no_window =
  { start = None
  ; start_offset = 0
  ; length = None
  ; mask = None
  ; newest_first = false
  }

type layer =
  | Fixed of
      { labels : string list
      ; interior : int
      ; payload : int
      }
  | Cases of shape list
  | Array_elements of
      { elements : elements
      ; window : window option
      }

(* A cons cell:  hd :: tl  is a two-field block, the head user data and
   the tail one cell deeper.  Cell labels stay the numeric "0"/"1" the
   wire has always used for cells. *)
let cons_cell =
  Fixed { labels = [ "0"; "1" ]; interior = 0b10; payload = 0b01 }

(* Bit i of a mask covers field i of the node the layer describes. *)
let layout = function
  (* a user-declared type has no hand-written skeleton: its root block
     is described by the schema the instrumentation derived, so the
     walk starts in schema mode and there are no layers at all *)
  | User -> []
  (* stdlib Map: every internal node is  Node {l; v; d; r; h}  (Empty is
     the int 0), and l/r lead to nodes of the same shape -- one layer,
     repeating.  The AVL height [h] is bookkeeping. *)
  | Map ->
    [ Fixed
        { labels = [ "l"; "v"; "d"; "r"; "h" ]
        ; interior = 0b01001 (* l, r *)
        ; payload = 0b00110 (* v, d *)
        } ]
  (* stdlib Set: Node {l; v; r; h}. *)
  | Set ->
    [ Fixed
        { labels = [ "l"; "v"; "r"; "h" ]
        ; interior = 0b0101 (* l, r *)
        ; payload = 0b0010 (* v *)
        } ]
  (* stdlib Queue: the root is  {length; first; last}  and each cell is
     Cons {content; next}  (Nil is the int 0), chained by [next] -- the
     cell layer repeats.  [last] is deliberately dropped: it is
     bookkeeping (the O(1) append pointer), and walking it would
     discover the tail cell as a direct child of the root before the
     chain reaches it, garbling the chain shape. *)
  | Queue ->
    [ Fixed
        { labels = [ "length"; "first"; "last" ]
        ; interior = 0b010 (* first *)
        ; payload = 0b001 (* length *)
        }
    ; cons_cell ]
  (* stdlib Hashtbl: the root is  {size; data; seed; initial_size},
     [data] is the bucket array, and each bucket is a
     Cons {key; data; next}  chain (Empty is the int 0).  Three layers:
     record -> array -> chain (repeating).  [seed] and [initial_size]
     are bookkeeping. *)
  | Hashtbl ->
    [ Fixed
        { labels = [ "size"; "data"; "seed"; "initial_size" ]
        ; interior = 0b0010 (* data *)
        ; payload = 0b0001 (* size *)
        }
    ; Array_elements { elements = Interior; window = None }
    ; Fixed
        { labels = [ "key"; "data"; "next" ]
        ; interior = 0b100 (* next *)
        ; payload = 0b011 (* key, data *)
        } ]
  (* stdlib Stack: the root is  {c; len}  over an ordinary list whose
     head is the top of the stack -- the same cell layer as a queue. *)
  | Stack ->
    [ Fixed
        { labels = [ "c"; "len" ]
        ; interior = 0b01 (* c *)
        ; payload = 0b10 (* len *)
        }
    ; cons_cell ]
  (* stdlib Dynarray: an unboxed  Pack  of  {length; arr; dummy}, so the
     value IS that record.  [arr] has room past [length] filled with the
     [dummy] value; the window keeps the walk to the live prefix. *)
  | Dynarray ->
    [ Fixed
        { labels = [ "length"; "arr"; "dummy" ]
        ; interior = 0b010 (* arr *)
        ; payload = 0b001 (* length *)
        }
    ; Array_elements
        { elements = Payload
        ; window = Some { no_window with length = Some 0 (* length *) }
        } ]
  (* Base/Core Map: a  {comparator; tree}  record (the comparator holds
     closures and is bookkeeping) over a tree of  Leaf {key; data}  and
     Node {left; key; data; right; weight}  (Empty is the int 0).  Base
     v0.16's root carried a third field [length] and its nodes were AVL,
     with a height where the weight now is -- the extra shapes accept
     both, since only the field COUNT and order matter here. *)
  | Core_map ->
    [ Cases
        [ { tag = None
          ; labels = [ "comparator"; "tree" ]
          ; interior = 0b10 (* tree *)
          ; payload = 0b00
          }
        ; { tag = None
          ; labels = [ "comparator"; "tree"; "length" ]
          ; interior = 0b010 (* tree *)
          ; payload = 0b100 (* length *)
          } ]
    ; Cases
        [ { tag = Some 0 (* Leaf *)
          ; labels = [ "v"; "d" ]
          ; interior = 0b00
          ; payload = 0b11 (* v, d *)
          }
        ; { tag = Some 1 (* Node *)
          ; labels = [ "l"; "v"; "d"; "r"; "w" ]
          ; interior = 0b01001 (* l, r *)
          ; payload = 0b00110 (* v, d *)
          } ] ]
  (* Base/Core Set: the same wrapper over  Leaf {elt}  and
     Node {left; elt; right; weight}.  Base v0.16's AVL node carried
     both a height and a subtree size, hence the five-field shape. *)
  | Core_set ->
    [ Cases
        [ { tag = None
          ; labels = [ "comparator"; "tree" ]
          ; interior = 0b10 (* tree *)
          ; payload = 0b00
          } ]
    ; Cases
        [ { tag = Some 0 (* Leaf *)
          ; labels = [ "v" ]
          ; interior = 0b0
          ; payload = 0b1 (* v *)
          }
        ; { tag = Some 1 (* Node *)
          ; labels = [ "l"; "v"; "r"; "w" ]
          ; interior = 0b0101 (* l, r *)
          ; payload = 0b0010 (* v *)
          }
        ; { tag = Some 1 (* Node, with a height and a subtree size *)
          ; labels = [ "l"; "v"; "r"; "h"; "s" ]
          ; interior = 0b00101 (* l, r *)
          ; payload = 0b00010 (* v *)
          } ] ]
  (* Base/Core Hashtbl: the root is
     {table; length; growth_allowed; hashable; iteration}  (that last
     field is [mutation_allowed] in Base v0.16, an iterator count
     since), [table] is the bucket array, and each bucket is an AVL tree
     of  Node {left; key; value; height; right}  and  Leaf {key; value}
     (Empty is the int 0).  Hash_set is  ('a, unit) Hashtbl.t  and so
     walks identically -- its values are all the unit int 0. *)
  | Core_hashtbl | Core_hash_set ->
    [ Cases
        [ { tag = None
          ; labels =
              [ "table"; "length"; "growth_allowed"; "hashable"
              ; "iteration" ]
          ; interior = 0b00001 (* table *)
          ; payload = 0b00010 (* length *)
          } ]
    ; Array_elements { elements = Interior; window = None }
    ; Cases
        [ { tag = Some 0 (* Node *)
          ; labels = [ "l"; "k"; "v"; "h"; "r" ]
          ; interior = 0b10001 (* l, r *)
          ; payload = 0b00110 (* k, v *)
          }
        ; { tag = Some 1 (* Leaf *)
          ; labels = [ "k"; "v" ]
          ; interior = 0b00
          ; payload = 0b11 (* k, v *)
          } ] ]
  (* Base/Core Queue: the root is
     {num_mutations; front; mask; length; elts}  and [elts] is a
     preallocated ring buffer -- element k lives at
     (front + k) land mask, and the slots outside that window hold a
     sentinel, not user data. *)
  | Core_queue ->
    [ Cases
        [ { tag = None
          ; labels =
              [ "num_mutations"; "front"; "mask"; "length"; "elts" ]
          ; interior = 0b10000 (* elts *)
          ; payload = 0b01000 (* length *)
          } ]
    ; Array_elements
        { elements = Payload
        ; window =
            Some
              { start = Some 1 (* front *)
              ; start_offset = 0
              ; length = Some 3 (* length *)
              ; mask = Some 2 (* mask *)
              ; newest_first = false
              }
        } ]
  (* Base/Core Stack: the root is  {length; elts}  over a preallocated
     array holding the stack in slots 0 .. length-1, bottom first --
     walked newest first, so the wire shows the top of the stack first,
     the way the stdlib Stack's list does. *)
  | Core_stack ->
    [ Cases
        [ { tag = None
          ; labels = [ "length"; "elts" ]
          ; interior = 0b10 (* elts *)
          ; payload = 0b01 (* length *)
          } ]
    ; Array_elements
        { elements = Payload
        ; window =
            Some
              { no_window with
                length = Some 0 (* length *)
              ; newest_first = true
              }
        } ]
  (* Core Deque: the root is
     {arr; front_index; back_index; apparent_front_index; length;
      arr_length; never_shrink}  and [arr] is a ring buffer whose live
     range starts one past [front_index] (that slot is where the next
     front enqueue goes) and wraps modulo the array's own size, which is
     not a power of two, so there is no mask to land on.  Cores without
     the trailing [never_shrink] flag are the six-field shape; the
     fields the window reads sit at the same indices in both. *)
  | Core_deque ->
    [ Cases
        [ { tag = None
          ; labels =
              [ "arr"; "front_index"; "back_index"
              ; "apparent_front_index"; "length"; "arr_length"
              ; "never_shrink" ]
          ; interior = 0b0000001 (* arr *)
          ; payload = 0b0010000 (* length *)
          }
        ; { tag = None
          ; labels =
              [ "arr"; "front_index"; "back_index"
              ; "apparent_front_index"; "length"; "arr_length" ]
          ; interior = 0b000001 (* arr *)
          ; payload = 0b010000 (* length *)
          } ]
    ; Array_elements
        { elements = Payload
        ; window =
            Some
              { start = Some 1 (* front_index *)
              ; start_offset = 1
              ; length = Some 4 (* length *)
              ; mask = None
              ; newest_first = false
              }
        } ]
  (* Core Fdeque (and Fqueue, which IS Fdeque): the root is
     {front; back; length}  over two ordinary lists, [back] holding the
     tail of the deque reversed. *)
  | Core_fdeque ->
    [ Fixed
        { labels = [ "front"; "back"; "length" ]
        ; interior = 0b011 (* front, back *)
        ; payload = 0b100 (* length *)
        }
    ; cons_cell ]
  (* Core Doubly_linked: the root is a ref holding the head element, and
     each element is  {value; prev; next; header}, [next] chaining
     CIRCULARLY back to the head (the walk stops at the revisit) while
     [prev] and the shared [header] are bookkeeping.  One repeating
     layer accepts both the option wrapper the ref holds and an element
     itself, which is also what makes a ref holding the element with no
     wrapper at all -- Core's or_null builds -- walk the same way. *)
  | Core_doubly_linked ->
    [ Fixed { labels = [ "contents" ]; interior = 0b1; payload = 0b0 }
    ; Cases
        [ { tag = Some 0 (* Some *)
          ; labels = [ "0" ]
          ; interior = 0b1
          ; payload = 0b0
          }
        ; { tag = Some 0 (* an element *)
          ; labels = [ "v"; "prev"; "next"; "header" ]
          ; interior = 0b0100 (* next *)
          ; payload = 0b0001 (* v *)
          } ] ]
  (* Core Hash_queue: the root is  {num_readers; queue; table}, where
     [queue] is a Doubly_linked.t of  Key_value {key; value}  pairs in
     queue order and [table] maps each key to the ELEMENT holding it.
     That table indexes the very cells [queue] already holds, so walking
     it would dump the whole queue a second time, cross-linked; it stays
     bookkeeping and the queue IS the structure.  The element layer is
     the doubly-linked one, so [next] stays on it while [v] steps down
     to the pair -- see [interior_targets]. *)
  | Core_hash_queue ->
    [ Fixed
        { labels = [ "num_readers"; "queue"; "table" ]
        ; interior = 0b010 (* queue *)
        ; payload = 0b000
        }
    ; Fixed { labels = [ "contents" ]; interior = 0b1; payload = 0b0 }
    ; Cases
        [ { tag = Some 0 (* Some *)
          ; labels = [ "0" ]
          ; interior = 0b1
          ; payload = 0b0
          }
        ; { tag = Some 0 (* an element *)
          ; labels = [ "v"; "prev"; "next"; "header" ]
          ; interior = 0b0101 (* v, next *)
          ; payload = 0b0000
          } ]
    ; Fixed
        { labels = [ "key"; "data" ]
        ; interior = 0b00
        ; payload = 0b11 (* key, data *)
        } ]

(* Only the hash queue needs one: its elements chain on their own layer
   while their payload steps down to the next.  [Some]'s field leads to
   the element layer too, because what the ref holds through the option
   IS an element. *)
let interior_targets = function
  | Core_hash_queue -> [ (2, [ ("0", 2); ("next", 2) ]) ]
  | Map | Set | Queue | Hashtbl | Stack | Dynarray | Core_map | Core_set
  | Core_hashtbl | Core_hash_set | Core_queue | Core_stack | Core_deque
  | Core_fdeque | Core_doubly_linked | User -> []

(* Labels must be ones [layout]'s shapes above actually use, and the
   field they name must be one the payload mask already keeps, so the
   schema for that role's type describes exactly the block that field
   points at.  ["*"] is an array layer's every element. *)
let payload_roles = function
  | User -> []
  | Map -> [ [ ("v", "key"); ("d", "data") ] ]
  | Set -> [ [ ("v", "elt") ] ]
  (* the root's [length] is a count, not user data *)
  | Queue | Stack -> [ []; [ ("0", "elt") ] ]
  (* likewise the root's [size]; the bucket array has no payload *)
  | Hashtbl -> [ []; []; [ ("key", "key"); ("data", "data") ] ]
  (* the live prefix of the buffer is the elements themselves *)
  | Dynarray | Core_queue | Core_stack | Core_deque ->
    [ []; [ ("*", "elt") ] ]
  (* one label per role serves both tree shapes, which put their key in
     different fields but call it [v] in each *)
  | Core_map -> [ []; [ ("v", "key"); ("d", "data") ] ]
  | Core_set -> [ []; [ ("v", "elt") ] ]
  | Core_hashtbl | Core_hash_set ->
    [ []; []; [ ("k", "key"); ("v", "data") ] ]
  (* both lists hold elements, and both walk with the same cell layer *)
  | Core_fdeque -> [ []; [ ("0", "elt") ] ]
  | Core_doubly_linked -> [ []; [ ("v", "elt") ] ]
  (* the pair the elements hold, not the elements themselves *)
  | Core_hash_queue ->
    [ []; []; []; [ ("key", "key"); ("data", "data") ] ]
