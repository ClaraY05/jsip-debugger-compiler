# vreplay/src -- the visual-replay runtime library

This directory is the library that `-visual-replay` links into every
instrumented program (never into the compiler itself): five OCaml
units plus two C files, built by `make vreplay` into `vreplay.cma` /
`vreplay.cmxa` with the C stubs archived alongside, otherlibs-style.

An **event** is one observation of a tracked value: a call on a
catalogued container (the DS traversal table below) or a `let` of a
value of the program's own declared types.  Each event is one sexp
line in the dump, carrying a walked snapshot of the value's in-memory
shape.

## How it works

```
compile time (typing/vreplay_instrumentation.ml)
  classify call --> splice:  {  call  Vreplay.snapshot per root  }
                                          |
run time (this library)                   v
  snapshot --> weak registry --> caml_wire_traverse (C walk)
          --> Sexp render     --> caml_wire_emit --> sink
```

**At compile time** the instrumentation (in `typing/`, part of
`ocamlcommon`) rewrites the typedtree: around each classified call it
emits a `{` frame marker, binds the result, and injects one
`Vreplay.snapshot` call per root -- each mutated container argument,
then a structure result -- with the `}` marker as a following binding.
Everything it can know statically travels as arguments: the location,
function and argument texts (in the interface repo's own type shapes),
the catalogue name, the printed type and its role-labelled parameters,
the binder and scope, and a schema derived from the user's type
declarations.  The compiler never links this library; the injected
code references it **by name** and resolves at the program's own
compile time (`-I vreplay/src`, or `+vreplay` once installed).  There
is no ppx anywhere in this path, deliberately.

**At run time**, one `snapshot` call does, in order
(`vreplay.ml`):

1. `Data_structure.of_name` -- an unknown catalogue name no-ops, so a
   compiler ahead of this library degrades silently rather than
   crashing the program.  Immediates are skipped: no identity.
2. `Vreplay_layout.layers_for` flattens the entry's layout (`layout`,
   `interior_targets`) into C-ready arrays, cached per entry.
3. `Vreplay_registry.register` finds or creates the root's entry in the **weak
   registry**: a stable id per structure, held via `Weak` so the GC is
   never disturbed and collected structures drop out of later events'
   registry fields.
4. `caml_wire_traverse` (`snapshot.c`) walks the heap from the root --
   a BFS with **no allocation during the walk** -- building the `node`
   tree: every kept field labelled, skeleton and payload told apart by
   the **edge** a block was reached through, walks stopping at any
   already-dumped block with an `(Id n)` reference.  The same walk
   captures the current address of every live registered structure,
   which becomes the event's `registry` field.
5. For an immutable structure's first dump, `absorb_members` remembers
   every dumped block (weakly) so later events can stop at them.
6. The event is rendered by `Sexp` and written through
   `caml_wire_emit` -- one line, flushed immediately.

**Deltas and sharing.**  Immutable structures (Map/Set and friends)
dump any block at most once in the whole dump; later occurrences are
`(Id n)`, and a re-observed structure collapses to a *revisit stub*
(its root id, current address, empty block/children).  Mutable
structures re-walk in full each event: the root keeps its registry id,
interior cells take fresh ids.  A reader reconstructs any event by
resolving `Id`s against earlier definitions.

**The sink** (`wire_sink.c`) is chosen lazily at the first event: `VREPLAY_SOCK`
(Unix stream socket; failed connect warns and falls through), else
`VREPLAY_FILE` (truncated), else `./vreplay.dump`.  Never stdout, so
program output cannot corrupt the dump.  If the sink cannot open, a
one-line stderr warning disables emission and the program runs on.
The `{`/`}` markers go through `caml_wire_emit` too -- a marker
written via `Printf` would sit in the stdout channel buffer until exit
and reorder after every payload.

## The modules

- `data_structure.{ml,mli}` -- the catalogue: the `t` variant, name
  round-trip, mutability, and per-entry layouts.  The `.mli` documents
  the layout vocabulary (`Fixed`/`Cases`/`Array_elements`, `window`,
  `interior_targets`, `payload_roles`) in place.
- `sexp.{ml,mli}` -- a minimal sexp AST (no sexplib in a compiler
  build) plus **the wire schema and its converters.  `sexp.mli` is the
  spec**; read it in full before changing anything about
  serialization.  `to_sexp`/`from_sexp` follow `[@@deriving sexp]`
  conventions so the interface repo mirrors the types and derives its
  reader.
- `vreplay_layout.{ml,mli}` -- layout flattening: the mini-compiler from
  `Data_structure.layer` to the C-ready `flat_shape`/`flat_layer`
  arrays the walker steers by.  Those records are transparent on
  purpose: their **field order is the contract** with the C mirror
  structs.
- `vreplay_registry.{ml,mli}` -- object identity: the weak registry of
  tracked structures and the member store of already-dumped blocks.
  Everything GC-aware lives here; identity is physical and resolved by
  scanning (addresses move, contents mutate -- nothing hashes).
- `vreplay.{ml,mli}` -- the facade the injected code targets:
  re-exports the schema types (same types, not copies), declares the
  two externals, assembles the event line, and owns `snapshot`, the
  injected entry point.  Its `.mli` is the whole contract the
  instrumentation and the interface repo see.
- `snapshot.c` -- `caml_wire_traverse`, the no-allocation BFS walker.
  Its structs mirror `vreplay_layout.ml`'s `flat_layer`/`flat_shape` and
  `sexp.ml`'s `block`/`node` **by declaration order** -- constructor
  and field order are the contract; change both sides or neither.
- `wire_sink.c` -- `caml_wire_emit` and sink selection: the only stub
  code touching the environment and OS I/O (sockets, Windows
  conditionals).

Both C files compile into the library's own stubs archives
(`libvreplay{byt,nat}.a` + the DLL), **not** the runtime, so any
ABI-compatible runtime resolves the primitives.

`Vreplay.from_sexp` + `Sexp.of_string` are the reference reader and
exact inverses of the emitters; `../tests/check_dump.ml` holds every
dump to that.

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

`User` is the one non-container entry: a value of a type the program
itself declared, observed at its `let`.  Its layout is empty -- the
shape comes from the schema the instrumentation derived from the
type declaration, not from a hand-written layout here.

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
3. `../tests/core_stubs/`: a stand-in unit with the same name and the same
   representation, plus a case in `../tests/cases/`. The stubs are what
   let CI cover Base and Core with no opam switch installed; they are
   not a substitute for running against the real thing once (see
   `README_opam_switch.md` in git history; deleted in the doc refresh).

The wire carries the entry's name as an atom, so the interface repo
needs a matching `Snapshot.Ds_type` constructor before it can read a
dump containing it.
