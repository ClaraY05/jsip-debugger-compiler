# vreplay/tests/ -- testing `-visual-replay`

Two halves, one directory: the automated **golden suite**
(`run_tests.sh`, `cases/`, `expected/`, `core_stubs/`, `check_dump.ml`) and
**by-hand recipes** for exercising the flag directly (formerly
`TEST.README.md`, merged here).  All commands run from the repo root.

## The golden suite

```sh
vreplay/tests/run_tests.sh              # run everything (needs a built tree)
vreplay/tests/run_tests.sh map_basic    # run selected cases
vreplay/tests/run_tests.sh --promote    # rewrite expected/ from output
```

When the tree also has a native compiler (`make opt`), every case runs
twice -- once compiled by `ocamlc`, once by `ocamlopt` (labelled
`[native]` in the output) -- against the **same** `expected/` dumps:
the wire format is backend-independent, so the two runs must agree up
to the address bijection.  Without `ocamlopt` the native pass is
skipped with a note.  `--promote` rewrites `expected/` from the
bytecode run only; the native pass then re-checks against the freshly
promoted goldens.

Before the cases, `check_catalogue.ml` runs once: every catalogue name
the instrumentation can emit (read from
`Vreplay_instrumentation.catalogue_names`, against
`compilerlibs/ocamlcommon`) must resolve in
`Data_structure.of_name` -- the tables live in two files, and this
turns a typo'd name (a silent runtime no-op) into a red test.

Each `cases/<name>.ml` is compiled with `-visual-replay` from the repo
root (so `loc` strings stay relative and stable), run, and checked two
ways:

1. **`check_dump`** validates the dump's structure: every line is a
   `{`/`}` marker run plus at most one sexp, every event has the
   wrapper fields in order (`id loc fn args registry ty binder scope
   snapshot`; `binder` is omitted for a root observed under no name),
   every snapshot round-trips exactly through
   `Vreplay.from_sexp`/`to_sexp`, depth returns to 0 at EOF, and the
   sharing invariants hold: node ids never repeat (except as an
   event's root -- for an immutable DS only as a revisit stub), every
   `(Id n)` resolves to an already-defined node, registry ids are
   dumped node ids, and addresses are unique within an event.
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
never emits its closing `}` (CLAUDE.md, "Known broken" #1), so
exception control flow would fail `check_dump`'s balance check by
design.  Add that case when depth becomes an explicit event field.

## By hand: build

```sh
make -j world        # bytecode build
make -j opt          # optional: ocamlopt, native runtime, vreplay.cmxa
```

Confirm the build actually relinked `ocamlc`:

```sh
ls -la --time-style=full-iso ocamlc driver/compile_common.cmo
# ocamlc must be NEWER than the .cmo
```

If you touched `vreplay/src/` (the runtime library linked into
instrumented programs), `make vreplay` rebuilds
`vreplay/src/vreplay.cma` (it is also part of `make world`).

## By hand: the invocation

A clone whose configured `prefix` does not exist (this one uses
`/usr/local`) cannot run a bare `./ocamlc foo.ml` -- it fails with
"required file not found", and the compiled program's shebang points at
a missing runtime.  Use the config-independent invocation instead:

```sh
runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay/src \
  -visual-replay \
  -use-runtime $PWD/runtime/ocamlrun -dllpath $PWD/vreplay/src \
  -o <out> <in.ml>
```

What each part is for:

- `runtime/ocamlrun ./ocamlc` -- run the freshly built compiler under
  the freshly built runtime, ignoring the broken shebang.
- `-nostdlib -I stdlib` -- use this tree's stdlib instead of the
  missing installed one.
- `-I vreplay/src` -- the injected code references `Vreplay`; this
  covers the `.cmi` at typing time and `vreplay.cma` at link time.
  (The `+vreplay` load-path entry only resolves under an installed
  standard library, so it is dead here.)
- `-visual-replay` -- the flag under test: instruments catalogued
  container calls and user-typed `let`s at the Typedtree layer.
- `-use-runtime $PWD/runtime/ocamlrun` -- this clone has no installed
  runtime for the shebang to point at.  Any ABI-compatible runtime
  works: the wire primitives live in the vreplay stubs DLL, not the
  runtime.
- `-dllpath $PWD/vreplay/src` -- bakes the stubs DLL's directory into
  the executable; without it the program dies at startup with
  `unknown C primitive caml_wire_emit` (an installed compiler needs
  neither flag -- its `stublibs/` covers the DLL).

The native equivalent, after `make opt` (no `-use-runtime`/`-dllpath`
-- native links the stubs statically from `libvreplaynat.a` via
`-cclib -lvreplaynat` recorded in `vreplay.cmxa`, and the executable
needs no shebang):

```sh
runtime/ocamlrun ./ocamlopt -nostdlib -I stdlib -I vreplay/src \
  -visual-replay -o <out> <in.ml>
```

## By hand: positive smoke -- Map program, three events

```sh
cat > /tmp/t.ml <<'EOF'
module M = Map.Make (String)
let () =
  let m = M.empty in
  let m = M.add "a" 1 m in
  let m = M.add "b" 2 m in
  let m = M.remove "a" m in
  ignore (M.find "b" m)
EOF
runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay/src \
  -visual-replay \
  -use-runtime $PWD/runtime/ocamlrun -dllpath $PWD/vreplay/src \
  -o /tmp/t.out /tmp/t.ml
VREPLAY_FILE=/tmp/t.dump /tmp/t.out && cat /tmp/t.dump
```

Exactly three events fire -- the two `M.add` and the `M.remove`.
`empty` is an ident (not an application), `find` returns the value
(not the map), and `ignore` is not a DS call, so none of those appear.

Each event is one line, wrapped in frame markers (`{` = depth +1, `}` =
depth -1).  Real output of the above (abridged and wrapped for
reading; regenerated 2026-08-05):

```
{(event (id 1) (loc ((file_path /tmp/t.ml) (line_number 4)
                     (char_range (10 23))))
   (fn (Function_name M.add))
   (args ((No_label (expression (Unnamed "\"a\"")))
          (No_label (expression (Unnamed 1)))
          (No_label (expression (Unnamed m)))))
   (registry ((1 0x77f8bffeeb68 m)))
   (ty ((printed "int M.t") (params ((key string) (data int)))))
   (binder T.m_478) (scope ((m T.m_478)))
   (snapshot ((ds_type Map) (root_node ((id 1)
     (virtual_address 0x77f8bffeeb68)
     (block ((l (Int 0)) (v (String a)) (d (Int 1)) (r (Int 0))))
     (children ()))))))
}{(event (id 2) ...
   (registry ((1 0x77f8bffeeb68 m) (2 0x77f8bffea750 m)))
   (binder T.m_617) (scope ((m T.m_617)))
   (snapshot ((ds_type Map) (root_node ((id 2) ...
     (block ((l (Int 0)) (v (String a)) (d (Int 1)) (r Child)))
     (children (((id 3) ... (block ((l (Int 0)) (v (String b))
                                    (d (Int 2)) (r (Int 0))))
                 (children ())))))))))
}{(event (id 3) ... (fn (Function_name M.remove))
   (binder T.m_618) (scope ((m T.m_618)))
   (snapshot ((ds_type Map) (root_node ((id 3)
     (virtual_address 0x77f8bffea780) (block ()) (children ()))))))
}
```

Field guide (`vreplay/src/sexp.mli` is the full spec):

- `id` -- the root structure's stable id in the weak registry.
- `loc` / `fn` / `args` -- computed at compile time, rendered in the
  interface repo's own type shapes so its reader is derived, not
  hand-written.  An argument the application was abstracted over
  renders as `OMITTED`.
- `registry` -- every tracked-and-alive structure as `(id address)` or
  `(id address name)`; grows as structures are tracked, drops
  GC-collected entries.  The name is the latest non-empty identifier
  the structure was observed under, so an entry can rename between
  events.  Addresses come from the same C walk as the nodes.
- `ty` -- the root's static type as printed off the typedtree, plus
  role-labelled parameters (`key`/`data`, `elt`) a reader displays
  without parsing OCaml.
- `binder` / `scope` -- which *binding* the root's name is
  (`unit.ident_stamp`, opaque; compare, never resolve), and what every
  tracked name in the unit means at this program point.  The registry
  above shows three live entries all called `m`; `scope` is what says
  which one the program can still reach.
- `snapshot` -- `Vreplay.to_sexp` of `{ ds_type; root_node }`, the
  walked in-memory shape (`l`/`v`/`d`/`r` are the Map's AVL node
  fields, labelled by the `Data_structure` catalogue; a field reading
  `Child` stands for the next entry of `children`).

Note the deltas: event 2 dumps only the rebuilt path (`b`'s node is
new, `a`'s re-dumped block carries a fresh id because the *path* to it
was rebuilt), and event 3 -- `M.remove "a"` returning the
already-dumped `b` subtree -- collapses to a **revisit stub**: root id
3 again, current address, empty `block` and `children`.

The reference reader is `Vreplay.from_sexp` + `Sexp.of_string` in
`vreplay/src/sexp.ml` -- exact inverses of the emitters.

## By hand: negative smoke -- no events, no dump file

Only classified calls and user-typed `let`s are instrumented, so a
plain-function program must produce no events.  The sink opens lazily
at the *first* event, so a clean negative leaves **no dump file at
all**, not an empty one (`run_tests.sh` pre-creates the file, which is
why `expected/neg_*.dump` are 0-byte):

```sh
printf 'let g x = x + 1\nlet f x = x + 2\nlet () = ignore (f (g 1))\n' \
  > /tmp/neg.ml
runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay/src \
  -visual-replay \
  -use-runtime $PWD/runtime/ocamlrun -dllpath $PWD/vreplay/src \
  -o /tmp/neg.out /tmp/neg.ml
rm -f /tmp/neg.dump
VREPLAY_FILE=/tmp/neg.dump /tmp/neg.out
test ! -e /tmp/neg.dump && echo "no events, as expected"
```

## Caveats when checking output

- **Exceptions unbalance the dump.**  A raising instrumented call
  never emits its closing `}`, so dumps from exception-using programs
  do not return to depth 0 (CLAUDE.md, "Known broken" #1).
- Addresses, binder stamps, and the exact `loc` path vary run to run
  and machine to machine; compare structure, not bytes.  (The golden
  suite's canonicalization handles addresses only -- its cases compile
  from the repo root precisely so locs and stamps stay stable.)
- `test_programs/map_test.ml` cannot be compiled here (depends on
  `Base`); use the inline programs above or `.tmp_files/tmp.ml`.

Broader project docs: `CLAUDE.md` (orientation, build, the wire
contract), `vreplay/src/README.md` (the catalogue and layout vocabulary).
