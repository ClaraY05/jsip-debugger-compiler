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

Then check whether the `Snapshot` module made it in:

```sh
strings compilerlibs/ocamlcommon.cma | grep -c '^Snapshot$'
```

## 3. If it did not relink

The cause is almost certainly `Makefile:91-92`: `snapshot.mli snapshot.ml` is listed in
`parsing_SOURCES`, which is wrapped in `$(addprefix parsing/, …)`, but the files actually
live at `typing/snapshot.{ml,mli}`. There is no `parsing/snapshot.ml`, so the target is
unsatisfiable.

Note that the similar-looking unprefixed entry at `Makefile:174`
(`vreplay_instrumentation.mli vreplay_instrumentation.ml` in `typing_SOURCES`) is **not**
a bug — `VPATH` at `Makefile:37` includes `typing`. VPATH does not rescue the `parsing/`
case because that prerequisite has an explicit directory component.

Report the diagnosis and the one-line fix, but **do not apply it** unless asked.

## 4. Summarize

State plainly: did it build, did it relink, and is `Snapshot` present.
