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
| `Core_doubly_linked` | Core | a ref over a circular element ring |

`Core.Linked_queue` is a `Stdlib.Queue.t` and so is walked as `Queue`:
entries follow the root's TYPE, never the module the call went through.

## Adding one

1. `data_structure.ml`/`.mli`: a constructor, its `to_string`/`of_name`
   spelling, and its `layout` -- the layers an interior walk meets, root
   first, the last one repeating. A layer lists every block shape it
   accepts (tag and field count), which is also how one layout covers
   several library versions; `Array_elements` takes a `window` when the
   live slots are bounded by fields of the parent record.
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
