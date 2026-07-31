# testing/ -- golden-dump and component tests for `-visual-replay`

```sh
testing/run_tests.sh              # golden end-to-end dumps (needs a built tree)
testing/run_tests.sh map_basic    # run selected cases
testing/run_tests.sh --promote    # rewrite expected/ from current output
testing/run_unit_tests.sh         # component tests (unit/, see below)
testing/run_unit_tests.sh walker  # one component test by name
```

## Golden dumps (`cases/` + `expected/`, run_tests.sh)

Each `cases/<name>.ml` is compiled with `-visual-replay` from the repo
root (so `loc` strings stay relative and stable), run, and checked two
ways:

1. **`check_dump`** validates the dump's structure: every line is a
   `{`/`}` marker run plus at most one sexp, every event has the six
   wrapper fields (`id loc fn args registry snapshot`), every snapshot
   round-trips exactly through `Vreplay.from_sexp`/`to_sexp`, and depth
   returns to 0 at EOF.
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
whole, boxed ints/bytes/unknown customs, closures as opaque addresses),
multi-root calls (`transfer`, containers of containers -- several
records inside one frame; `transfer q q` deduping to one record), the
dump sink (program stdout kept separate; a `VREPLAY_SOCK` listener),
the weak registry dropping GC'd structures,
tracked-structure-inside-tracked-structure `(Id _)` boundaries, payload
strings full of quoting hazards (`map_string_escaping`), an
immediate-result event's empty frame (`map_empty_result`), and
negatives (plain functions, partial application, a user module
shadowing a tracked name, non-ident structure arguments, Stack/list/
array which are deliberately uncovered today).

## Component tests (`unit/`, run_unit_tests.sh)

Where the goldens check the pipeline end to end, `unit/test_<name>.ml`
programs pin one component each, with assertions instead of dump diffs
(TAP-ish `ok`/`not ok` lines; `tap.ml` is the shared helper).  They are
compiled **without** `-visual-replay` -- they call the runtime pieces
directly, and instrumenting them would pollute their own dumps:

- `test_sexp.ml` -- `Sexp.to_string`/`of_string` as exact inverses
  (every escape, all 256 bytes, parse failures), wire converters
  round-tripping every `block` kind, floats bit-exact on the wire, and
  the loc/fn/args/registry renderers' exact shapes.
- `test_registry.ml` -- the weak registry via `Vreplay.snapshot` (it is
  private by design): stable per-object ids, no id reuse after
  retirement, insertion-order echo, GC'd entries dropped (the hold is
  weak), the root echoed at its node's address, `(Id _)` boundaries for
  tracked structures inside tracked structures, and the no-event cases
  (immediate roots, unknown ds names).
- `test_walker.ml` -- `caml_wire_traverse` re-declared by its C name and
  driven directly: mask semantics per layer, payload-by-edge (never by
  shape), size-mismatch demotion, `Array_elements`, last-layer
  repetition, `known` boundaries, echo order, sharing (one node, two
  parents; printer emits revisits childless), cycles terminating, leaf
  decodings (incl. NULs, all-float records flattening, unknown customs),
  the 64-field mask-width limit, and first-edge mode fixing.

`unit/raise_unbalanced.ml` is the exception: the runner compiles it
*with* `-visual-replay` to pin the known limitation below -- the dump
must be exactly one dangling `{`.

Known limitation, deliberately pinned rather than golden-tested: a
raising instrumented call never emits its closing `}` (bug 5), so
exception control flow would fail `check_dump`'s balance check by
design.  `run_unit_tests.sh raise_unbalanced` asserts the current
behavior; flip that expectation when frames become exception-safe.
