An event is defined as every time a known data structure (as recorded in our DS traversal info table) is created or manipulated

## The catalogue

`data_structure.ml` names one entry per REPRESENTATION, not per module:
`Core.Map`, `Base.Map`, `Map.Poly`, `Int.Map` and every `Make` instance
are one type at runtime, so they are one entry (`Core_map`).

| entry | covers | shape |
| --- | --- | --- |
| `Map` `Set` `Queue` `Hashtbl` | stdlib | AVL nodes; `{length; first; last}` + cell chain; record + bucket array + chain |
| `Stack` | stdlib | `{c; len}` over a list |
| `Dynarray` | stdlib | unboxed `{length; arr; dummy}`, live prefix of `arr` |
| `Core_map` `Core_set` | Base/Core | `{comparator; tree}` (`+ length` in v0.17) over `Leaf`/`Node` |
| `Core_hashtbl` `Core_hash_set` | Base/Core | record → bucket array → AVL tree; a hash set IS a table of `unit` |
| `Core_queue` `Core_stack` `Core_deque` | Base/Core | preallocated buffers; only the live window is walked |
| `Core_fdeque` | Core (`Fdeque`, `Fqueue`) | `{front; back; length}` over two lists |
| `Core_doubly_linked` | Core (`Doubly_linked`, `Bag`) | a ref over a circular element ring |
| `Core_hash_queue` | Core | that ring in queue order; the table indexing it is bookkeeping |
| `Core_union_find` | Core | an inverted forest: nodes point UP at a shared root record |
| `Core_map_tree` `Core_set_tree` | Base/Core (`Map.Tree`, `Set.Tree`) | the parents' tree layer with no comparator record on top |

`Core.Linked_queue` is a `Stdlib.Queue.t` and so is walked as `Queue`:
entries follow the root's TYPE, never the module the call went through.
`Core.Bag` goes the other way -- its representation IS a doubly-linked
list, sealed into a type of its own, so Bag's units are named in both
tables and the list's layout walks it.

Auxiliary types a container declares beside its own `t` share its
compilation unit, so a type reached through one travels QUALIFIED by
that module (`Base__Map.Tree`) and the catalogue claims the ones it
describes. The rest -- `Comparator`, `Hashable`, `Doubly_linked.Elt` --
match nothing and are left alone. `Elt` is deliberately among them: a
list's `insert` and a bag's `add` both RETURN one, and claiming the type
would mint a structure per insertion.

## Adding one

1. `data_structure.ml`/`.mli`: a constructor, its `to_string`/`of_name`
   spelling, and its `layout` -- the layers an interior walk meets, root
   first, the last one repeating. A layer lists every block shape it
   accepts (tag and field count), which is also how one layout covers
   several library versions; `Array_elements` takes a `window` when the
   live slots are bounded by fields of the parent record, and
   `interior_targets` names the layer a field leads to when it is not
   simply the next one down (a hash queue's elements chain on their own
   layer, a union-find node's `parent` steps back to layer 0).
2. `typing/vreplay_instrumentation.ml`: the unit the TYPE is declared in
   (`ds_of_type_unit`) and the units of the modules whose calls are
   events (`ds_table`), with the entries each module operates on. For
   Base and Core both are usually the `_intf` unit the module type came
   from, not the implementation -- a wrong guess shows up as an event
   that never fires, so check against the real library.
3. `testing/mock/`: a stand-in unit with the same name and the same
   representation, plus a case in `testing/cases/`. The mocks are what
   let CI cover Base and Core with no opam switch installed; they are
   not a substitute for running against the real thing once
   (`README_opam_switch.md`).

The wire carries the entry's name as an atom, so the interface repo
needs a matching `Snapshot.Ds_type` constructor before it can read a
dump containing it.
