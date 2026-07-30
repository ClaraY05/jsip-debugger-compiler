# testing/ -- golden-dump tests for `-visual-replay`

```sh
testing/run_tests.sh              # run everything (needs a built tree)
testing/run_tests.sh map_basic    # run selected cases
testing/run_tests.sh --promote    # rewrite expected/ from current output
```

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
   (ids, locs, args, shapes, registry linkage) must match exactly.

After changing the wire format deliberately, re-run with `--promote`
and review the diff of `expected/` like any other code change.

What the cases cover: Map/Set/Queue positive paths (including reads
that fire by design, e.g. `Queue.pop`/`peek`), classification through
`open`/aliasing and via result types (`fold` producing a map), nested
events and their depth markers, the args field, data representations
(floats, tuples-as-children), the weak registry dropping GC'd
structures, tracked-structure-inside-tracked-structure `(Id _)`
boundaries, and negatives (plain functions, partial application,
Hashtbl/Stack/list/array which are deliberately uncovered today).

Known limitation, deliberately untested: a raising instrumented call
never emits its closing `}` (REVIEW_FINDINGS #3), so exception control
flow would fail `check_dump`'s balance check by design. Add that case
when depth becomes an explicit event field.
