---
description: Compile a program with -visual-replay, run it, and inspect the dump
argument-hint: "[path/to/file.ml]  (default: .tmp_files/tmp.ml)"
allowed-tools: Bash(./ocamlc:*), Bash(./a.out), Bash(ls:*), Bash(cat:*), Bash(grep:*), Read
---

Exercise the `-visual-replay` feature end to end on: **$ARGUMENTS**

If no argument was given, use `./.tmp_files/tmp.ml` — the authors' working scratch input.

## 1. Sanity-check the input

Do **not** use `test_programs/map_test.ml`. It opens `Base`, which exists only in opam
switches whose CMI magic is incompatible with this compiler. It cannot be built here at
any `-I`. If the user passed it, say so and fall back to `.tmp_files/tmp.ml`.

## 2. Compile and run

```sh
./ocamlc -visual-replay <file.ml>
./a.out
```

No `-I` or stdlib flags are needed. Use the `./ocamlc` in the repo root — **never**
`_install/bin/ocamlc*`, which is committed junk with a dangling shebang.

If the program dies at startup with `unknown C primitive caml_wire_emit`, the stubs DLL
was not found: the primitives live in `vreplay/dllvreplaybyt-*.so` (built with the
library), not in any runtime. Fix by linking with `-dllpath $PWD/vreplay` (in-tree) or
`make install` (the DLL lands in `stublibs/`, which `ld.conf` covers). A shebang failure
(`required file not found`) is separate — fix with `-use-runtime runtime/ocamlrun`.

## 3. Report what came out, and judge it against the contract

Show the raw output. Then assess it against what the interface actually parses
(`~/jsip-debugger-interface/lib/parsing/src/dump_reader.ml`, branch `origin/parsing`):

```
:111  "%[^F]FUNCTION(%[^)]) ARGUMENTS(%[^)]) LOCATION(%[^)])"
:10   "%[^:]:[%[^]]]"                             -> lowercase: function_name | unnamed
:28   "LABEL:[{%[^}]}{%[^}]}] ARGUMENT:[%[^]]]"   -> args split on ';'
:76   "File %[^,], line %d, characters %d-%d"
```

State plainly which of these the output satisfies and which it does not. Expected today:
**bare brackets only** (e.g. `{{}{}{}{}}`) — because injection still hardcodes
`~inject:(call_c_node "meow")` at `typing/vreplay_instrumentation.ml:191` and the
sexp-formatting path is commented out at lines 84-86. That is the known state, not a new
bug; say so rather than reporting it as a fresh discovery.

Compare against the reference fixture at `~/jsip-debugger-interface/app/bin/dummy.txt`
if a shape comparison would help.

## 4. If nothing changed after a rebuild

Check that `./ocamlc` actually relinked — see `/build`. A stale binary is the single most
common cause of "my edit did nothing" in this tree.
