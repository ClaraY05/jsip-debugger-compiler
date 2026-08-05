# jsip-debugger-compiler -- OCaml with `-visual-replay`

A fork of the OCaml compiler (5.5 line, upstream base `466e585663`)
carrying **one feature**: a `-visual-replay` flag that instruments an
OCaml program at the Typedtree layer so that, when run, it dumps one
sexp event per observed value -- each call on a catalogued container
(stdlib and Base/Core `Map`/`Set`/`Queue`/`Hashtbl`/... ) and each
`let` of a value of the program's own declared types -- carrying a
walked snapshot of that value's in-memory shape.

It is one half of the
[jsip-visual-debugger](https://github.com/ClaraY05/jsip-visual-debugger)
project, which holds both halves as git submodules (this one pinned at
`vreplay-main`) and drives the one-command end-to-end pipeline: build
this fork, compile a program under `-visual-replay`, run it, open the
TUI on the dump.  The other half
([jsip-debugger-interface](https://github.com/wuad391/jsip-debugger-interface))
is a `bonsai_term` TUI that steps through the dump GDB-style, showing
the call stack, the source, and the heap shapes.  Goal: visualize data
structures as the user steps through a replay of their program,
without needing to know assembly.

Upstream's own README is [README.adoc](../README.adoc).  Everything below
is about the fork.

## Using it

```sh
./configure --prefix=$PWD/_install
make -j world            # bytecode compiler + the vreplay library
make -j opt              # optional: native compiler + vreplay.cmxa
```

Compile and run a program with the flag (config-independent
invocation; an installed compiler needs only `-visual-replay`):

```sh
runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay/src \
  -visual-replay \
  -use-runtime $PWD/runtime/ocamlrun -dllpath $PWD/vreplay/src \
  -o prog prog.ml
VREPLAY_FILE=prog.dump ./prog
```

The dump sink is chosen by environment -- `VREPLAY_SOCK` (live
socket), `VREPLAY_FILE`, or `./vreplay.dump` -- never stdout.  Run the
golden test suite with `vreplay/tests/run_tests.sh`.  See
[vreplay/tests/README.md](../vreplay/tests/README.md) for the full
walkthrough and [CLAUDE.md](../CLAUDE.md) for complete orientation.

## What the fork changes, relative to upstream

The whole feature is ~150 files against the upstream base; almost all
of it lives in directories the project owns.

**New, project-owned:**

| Where | What |
| --- | --- |
| `typing/vreplay_instrumentation.{ml,mli}` | The heart: a `Tast_mapper` that classifies applications by provenance and splices frame markers, a result binding, and a `Vreplay.snapshot` call per observed root into the typed AST. One inner module per concern (`Wire`, `Catalogue` -- one table, `declares`/`observes` per unit -- `Classify`, `Schema`, `Scope`, `Inject`) behind a two-value interface. |
| `vreplay/src/` | The runtime library linked into instrumented programs (never into the compiler), five units plus two C files: the data-structure catalogue and layouts, the sexp wire schema (`sexp.mli` is the spec), layout flattening (`vreplay_layout`, the field-order contract with the walker), the weak registry (`vreplay_registry`), the `Vreplay` façade with the `snapshot` entry point, `snapshot.c` (the C heap walker) and `wire_sink.c` (the dump sink). See [vreplay/src/README.md](../vreplay/src/README.md) for how it works. |
| `vreplay/tests/` | The golden-dump suite: 49 cases, their expected dumps (verbatim run output, reused by the interface repo as parser fixtures), Base/Core stub units (`core_stubs/`) so CI needs no opam switch, `check_dump.ml` (structural validator), and `check_catalogue.ml` (every catalogue name the instrumentation can emit must resolve in the runtime library -- a typo is a red test, not a silent no-op). |

**Modified upstream compiler files -- all small and surgical:**

| File | Change |
| --- | --- |
| `driver/compile_common.ml` | +2 lines: the one hookpoint, piping the typed AST through the instrumentation when the flag is set. |
| `utils/clflags.{ml,mli}` | The `visual_replay` flag ref. |
| `driver/main_args.{ml,mli}` | `-visual-replay` option wiring in the frontends. |
| `driver/compmisc.ml` | Adds `+vreplay` to the load path under the flag. |
| `bytecomp/bytelink.ml`, `asmcomp/asmlink.ml` | Under the flag, prepend `vreplay.cma` / `vreplay.cmxa` right after the stdlib archive. |
| `toplevel/toploop.ml` | Warns that the flag is accepted but ignored in the toplevel (not yet implemented there). |

**Build and infrastructure:** the `Makefile` gains the `vreplay`
library block (OCaml halves plus, via `ocamlmklib`, the C stubs
archives that travel with the library -- the primitives live there,
not in the runtime, so any ABI-compatible runtime works);
`.gitattributes` exempts project files from upstream's license-header
check; plus matching `.depend`/`.gitignore`/opam-metadata touches.
The dune files gain a module entry but **dune is not the build
system here** -- `make` is.

Nothing else in the ~1M-line upstream tree is touched, and the
instrumentation is a no-op without the flag: a compiler built from
this tree behaves as stock OCaml unless `-visual-replay` is passed.

## The wire format, in one glance

```
{(event (id 1) (loc ...) (fn (Function_name M.add)) (args ...)
   (registry ((1 0x7c4d... m))) (ty ((printed "int M.t") ...))
   (binder T.m_478) (scope ((m T.m_478)))
   (snapshot ((ds_type Map) (root_node ...))))
}
```

One line per event; `{`/`}` markers carry call depth.  Dumps are
deltas: immutable structures dump any block at most once, later
occurrences are `(Id n)` references, so sharing is visible to the
reader.  `vreplay/src/sexp.mli` is the authoritative spec;
`Vreplay.from_sexp` is the reference reader.

## Repo geography

- `vreplay-main` is the integration branch and PR base; `trunk` is the
  historical upstream fork point only.
- Deeper docs: [CLAUDE.md](../CLAUDE.md) (orientation, build, known
  issues, conventions), [vreplay/src/README.md](../vreplay/src/README.md)
  (the library and catalogue),
  [vreplay/tests/README.md](../vreplay/tests/README.md) (testing, by-hand
  recipes).
