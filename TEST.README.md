# TEST.README -- exercising `-visual-replay` and its sexp output

Quick commands to build the instrumented compiler, run the custom
`-visual-replay` flag on a test program, and inspect the sexp dump it emits.
All commands run from the repo root. Every command here was verified working
in this checkout on 2026-07-30.

## 1. Build

```sh
make -j world        # bytecode build
make -j opt          # optional: ocamlopt, native runtime, vreplay.cmxa
```

Confirm the build actually relinked `ocamlc`:

```sh
ls -la --time-style=full-iso ocamlc driver/compile_common.cmo
# ocamlc must be NEWER than the .cmo
```

If you touched `vreplay/` (the runtime library linked into instrumented
programs), `make vreplay` rebuilds `vreplay/vreplay.cma` (it is also part of
`make world`).

## 2. The invocation

This checkout is configured with `prefix=/usr/local`, which does not exist,
so a bare `./ocamlc foo.ml` fails ("required file not found") and the
compiled program's shebang points at a missing runtime. Use this
config-independent invocation instead:

```sh
runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay -visual-replay \
  -use-runtime $PWD/runtime/ocamlrun -o <out> <in.ml>
```

What each part is for:

- `runtime/ocamlrun ./ocamlc` -- run the freshly built compiler under the
  freshly built runtime, ignoring the broken shebang.
- `-nostdlib -I stdlib` -- use this tree's stdlib instead of the missing
  installed one.
- `-I vreplay` -- the injected code references `Vreplay`; this covers the
  `.cmi` at typing time and `vreplay.cma` at link time. (The `+vreplay`
  load-path entry only resolves under an installed standard library, so it
  is dead here.)
- `-visual-replay` -- the flag under test: instruments Map/Set (and other
  `ds_table`) calls at the Typedtree layer.
- `-use-runtime $PWD/runtime/ocamlrun` -- the output program needs
  `caml_wire_emit`/`caml_wire_traverse`, which only this tree's runtime has.

The native equivalent, after `make opt` (verified 2026-08-04; no
`-use-runtime` -- the primitives are already in this tree's `libasmrun.a`,
and the executable needs no shebang):

```sh
runtime/ocamlrun ./ocamlopt -nostdlib -I stdlib -I vreplay -visual-replay \
  -o <out> <in.ml>
```

## 3. Positive test -- Map program, expect three sexp events

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
runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay -visual-replay \
  -use-runtime $PWD/runtime/ocamlrun -o /tmp/t.out /tmp/t.ml
/tmp/t.out
```

Exactly three events fire -- the two `M.add` and the `M.remove`. `empty` is
an ident (not an application), `find` returns the value (not the map), and
`ignore` is not a DS call, so none of those appear.

Each event is one line, wrapped in frame markers (`{` = depth +1, `}` =
depth -1), shaped like:

```
{(event (id 1)
   (loc "File \"/tmp/t.ml\", line 4, characters 10-23")
   (fn M.add)
   (args ((NO_LABEL "\"a\"") (NO_LABEL 1) (NO_LABEL m)))
   (registry ((1 0x7f... m)))
   (snapshot ((ds_type Map)
     (root_node ((virtual_address 0x7f...)
       (block ((l (Int 0)) (v (String a)) (d (Int 1)) (r (Int 0))))
       (children ()))))))
}
```

(wrapped here for reading; on the wire it is one line per event)

Field guide:

- `id` -- the structure's id in the weak registry.
- `args` -- the call's arguments as (label-kind, source-text) pairs,
  computed at compile time: NO_LABEL / LABELLED:l / OPTIONAL:l, and
  OMITTED for an argument the application was abstracted over.
- `registry` -- every tracked-and-alive structure as an `(id address)`
  or `(id address name)` entry; grows as structures are tracked, drops
  GC-collected entries. The optional `name` is the identifier the
  structure was last observed under -- the `let` binder when the call
  is exactly the RHS of a `let`, or a mutated container argument's own
  identifier; the latest non-empty name wins, so an entry can rename
  between events, and it is absent while the structure is anonymous.
  It is the single source of memory locations for tracked structures:
  a nested tracked structure appears in a snapshot as `(Id i)`,
  resolved by indexing this registry. Addresses come from the same C
  walk as the nodes.
- `snapshot` -- `Vreplay.to_sexp` of `{ ds_type; root_node }`, the walked
  in-memory shape (`l`/`v`/`d`/`r` here are the Map's AVL node fields:
  left, value, data, right -- per the `Data_structure` catalogue).

The reference reader is `Vreplay.from_sexp` + `Sexp.of_string` in
`vreplay/sexp.ml` -- exact inverses of the emitters.

## 4. The test suite

The above by hand, plus much more, lives in `testing/`:

```sh
testing/run_tests.sh    # golden dumps + structural checks, see testing/README.md
```

## 5. Negative test -- plain functions, expect an empty dump

Only calls into modules in `classify`'s `ds_table` are instrumented, so a
program with no data-structure calls must dump nothing:

```sh
printf 'let g x = x + 1\nlet f x = x + 2\nlet () = ignore (f (g 1))\n' \
  > /tmp/neg.ml
runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay -visual-replay \
  -use-runtime $PWD/runtime/ocamlrun -o /tmp/neg.out /tmp/neg.ml
/tmp/neg.out | wc -c    # must print 0
```

## 6. Caveats when checking output

- **Exceptions unbalance the dump.** A raising instrumented call never emits
  its closing `}`, so dumps from exception-using programs do not return to
  depth 0. Known issue -- `REVIEW_FINDINGS.md` #3.
- **Queue is fully supported** (mutable: `create` roots at the result,
  everything else at the queue argument, re-read post-call; the id is
  stable across events because it is one structure mutated in place).
  **Hashtbl and Stack are deliberately out of `ds_table`** until the
  runtime catalogue has their layouts -- their calls emit nothing.
- `test_programs/map_test.ml` cannot be compiled here (depends on `Base`);
  use the inline programs above or `.tmp_files/tmp.ml`.
- Addresses and the exact `loc` path vary run to run and machine to
  machine; compare structure, not bytes.

Full known-issue list with repros: `REVIEW_FINDINGS.md`. Broader project
docs: `CLAUDE.md` (note its "bare `./ocamlc` works, no `-I` needed" section
assumes a `--prefix=$PWD/_install` configure that this checkout no longer
has).
