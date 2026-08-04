# testing/ -- golden-dump tests for `-visual-replay`

```sh
testing/run_tests.sh              # run everything (needs a built tree)
testing/run_tests.sh map_basic    # run selected cases
testing/run_tests.sh --promote    # rewrite expected/ from current output
```

When the tree also has a native compiler (`make opt`), every case runs
twice -- once compiled by `ocamlc`, once by `ocamlopt` (labelled
`[native]` in the output) -- against the **same** `expected/` dumps:
the wire format is backend-independent, so the two runs must agree up
to the address bijection.  Without `ocamlopt` the native pass is
skipped with a note.  `--promote` rewrites `expected/` from the
bytecode run only; the native pass then re-checks against the freshly
promoted goldens.

Each `cases/<name>.ml` is compiled with `-visual-replay` from the repo
root (so `loc` strings stay relative and stable), run, and checked two
ways:

1. **`check_dump`** validates the dump's structure: every line is a
   `{`/`}` marker run plus at most one sexp, every event has the seven
   wrapper fields (`id loc fn args registry ty snapshot`), every
   snapshot round-trips exactly through `Vreplay.from_sexp`/`to_sexp`,
   depth returns to 0 at EOF, and the sharing invariants hold: node
   ids never repeat (except as an event's root — for an immutable DS
   only as a revisit stub), every `(Id n)` resolves to an
   already-defined node, registry ids are dumped node ids, and
   addresses are unique within an event.
2. **Golden diff** against `expected/<name>.dump`.  The expected files
   are **verbatim dumps of a real run** -- byte-for-byte what the
   interface's reader will be fed, usable directly as parser fixtures.
   Raw heap addresses differ run to run, so the *comparison* (never the
   stored files) canonicalizes both sides identically -- each distinct
   address becomes `0xA<n>` by first appearance -- making the check
   "equal up to a consistent address bijection".  Everything else
   (ids, locs, args, shapes, registry linkage and names) must match
   exactly.

After changing the wire format deliberately, re-run with `--promote`
and review the diff of `expected/` like any other code change.

What the cases cover: Map/Set/Queue/Hashtbl positive paths (including
reads that fire by design, e.g. `Queue.pop`/`peek`), classification
through `open`/aliasing and via result types (`fold` producing a map),
nested events and their depth markers, the args field, data
representations (floats, tuples-as-children, wide payload tuples kept
whole, closures as opaque addresses), multi-root calls (`transfer`,
containers of containers -- several records inside one frame), the
dump sink (program stdout kept separate; a `VREPLAY_SOCK` listener),
the weak registry dropping GC'd structures,
tracked-structure-inside-tracked-structure `(Id _)` boundaries,
structure sharing (`map_versions`: version chains dump only the
rebuilt path, and shared blocks keep their ids after their owning
version is collected; `map_shared_payload`: one record under several
keys stays one definition; `map_rewalk`: a re-observed map collapses
to a revisit stub; `queue_cycle`: a payload cycle becomes an `(Id _)`
back-reference), and
negatives (plain functions, partial application, Stack/list/array
which are deliberately uncovered today).

Known limitation, deliberately untested: a raising instrumented call
never emits its closing `}` (REVIEW_FINDINGS #3), so exception control
flow would fail `check_dump`'s balance check by design. Add that case
when depth becomes an explicit event field.
