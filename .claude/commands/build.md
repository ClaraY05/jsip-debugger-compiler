---
description: Build the compiler (bytecode) and verify ocamlc actually relinked
allowed-tools: Bash(make:*), Bash(ls:*), Bash(strings:*), Bash(grep:*), Read
---

Build this OCaml compiler fork and **verify the build actually took effect**.

## 1. Build

This machine has 4 cores. Bytecode only — native has never built in this tree, so use
`world`, not `world.opt`:

```sh
make -j world
```

If `-j` is too aggressive (OOM, thrashing), fall back to `make -j 2 world`.

Report any compile errors verbatim rather than summarizing them.

## 2. Verify it relinked — do not skip this

A known `Makefile` bug can leave `./ocamlc` silently stale, so a "successful" build does
not mean your change is in the binary. Check:

```sh
ls -la --time-style=full-iso ocamlc driver/compile_common.cmo
```

`ocamlc` must be **newer** than the `.cmo`. If it is older, the link step did not run.

Then check whether the instrumentation unit made it in (`strings` on a `.cma` is a
false negative — use ocamlobjinfo):

```sh
runtime/ocamlrun ./tools/ocamlobjinfo compilerlibs/ocamlcommon.cma \
  | grep Vreplay_instrumentation
```

## 3. If it did not relink

The historical cause (a bad `parsing_SOURCES` prefix on a `snapshot` unit) is fixed and
the unit itself is gone — the wire primitives now live in `vreplay/src/snapshot.c`, built
into the vreplay stubs archives, not in any compilerlibs unit or the runtime. A build
that dies at startup with `unknown C primitive` means stale bytecode binaries against a
regenerated primitives table: `make partialclean && make world`.

Report the diagnosis, but **do not apply fixes** unless asked.

## 4. Summarize

State plainly: did it build, did it relink, and is `Snapshot` present.
