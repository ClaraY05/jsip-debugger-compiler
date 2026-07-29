# CLAUDE.md — jsip_debugger

## What this repo is

A **fork of the OCaml compiler** (fork point `511483454`, upstream 5.6.0+dev) carrying one
feature: a `-visual-replay` flag that injects instrumentation into an arbitrary OCaml
program at the **Typedtree** layer, so that running the compiled program dumps a log of
every function call it makes.

This is one half of a two-repo project:

```
jsip_debugger  (this repo)          ~/jsip-debugger-interface
  instrumented ocamlc                 bonsai-term TUI
  ./ocamlc -visual-replay foo.ml  →  text dump on stdout  →  visual replay of data structures
```

**You are almost always working on the compiler half.** The interface half lives at
`~/jsip-debugger-interface` (git remote `wuad391/jsip-debugger-interface`, active branch
`origin/parsing`). `~/jsip-visual-debugger` is a dead scaffold — ignore it.

Goal of the project: visualize allocated data and data structures as the user steps
through a replay of their program — a TUI debugger that doesn't require knowing assembly.

---

## Orient fast: the project's own files

This tree is ~1M lines of upstream OCaml. **Everything the project actually wrote is
this list.** If you are grepping the whole tree, you are probably lost.

| File | Role |
|---|---|
| `typing/vreplay_instrumentation.ml` / `.mli` | **The heart.** A `Tast_mapper` that rewrites every `Texp_apply` to emit instrumentation around the call. |
| `driver/compile_common.ml:117` | The hookpoint — one line, pipes the typed AST through the mapper. |
| `typing/snapshot.ml` / `.mli` | `external emit : string -> unit = "caml_wire_emit"` |
| `runtime/snapshot.c` | Defines `caml_wire_emit`; currently just `fprintf`s to stdout. |
| `utils/clflags.ml:255`, `.mli:225` | `let visual_replay = ref false` |
| `driver/main_args.ml:698` + 5 module lists | `-visual-replay` flag wiring. |
| `Makefile:92`, `:174`, `:1251` | Build wiring for the above (see **Known broken** — `:92` is wrong). |
| `vreplay/` | **Empty stubs.** `vreplay.ml`/`.c` are 0 bytes; `vreplay.mli` is prose pseudocode, not valid OCaml. Not currently built. |
| `test_programs/map_test.ml` | Test input — **cannot be compiled by this tree** (see below). |

To see project work vs upstream for any path:

```sh
git diff 511483454 HEAD -- <path>     # 511483454 = the fork point
```

---

## Build

**`make` is the live build system. Dune is not.** The `_build/` directory predates all
vreplay work and cannot produce `./ocamlc`; dune exists here only as a Merlin helper
(`HACKING.adoc:518`). Ignore `_build/`.

Configure has already been run as `./configure --prefix=$PWD/_install`
(`Makefile.config:40`). You should not need to re-run it.

```sh
make -j world          # full/incremental build (bytecode). This machine has 4 cores.
make -j 2 world        # if -j is too aggressive
```

- **Bytecode only.** Native has never successfully built in this tree — there is no
  `ocamlopt` and no `ocamlc.opt`. Use `make world`, **not** `make world.opt`.
- After editing anything in `typing/`, `driver/`, `utils/`: just `make -j world`.
- After editing a `.c` in `runtime/`: also just `make -j world`. `runtime/primitives`
  and `runtime/prims.c` are regenerated automatically (`Makefile:1454-1460`).
  Only `rm runtime/primitives runtime/prims.c` if you **added a new primitive name** and
  hit a phantom "unavailable primitive" error.
- **`make bootstrap` is not needed** for this project's kind of change.
- Adding a new `.c` file to the runtime means adding its stem to
  `runtime_COMMON_C_SOURCES` (`Makefile:1251`).

**Always confirm the build actually relinked** (see Known broken #1):

```sh
ls -la --time-style=full-iso ocamlc driver/compile_common.cmo
# ocamlc must be NEWER than the .cmo, or your change is not in the binary
```

---

## Run the feature end to end

```sh
./ocamlc -visual-replay ./.tmp_files/tmp.ml    # writes ./a.out
./a.out                                         # currently prints: {{}{}{}{}}
```

No `-I` or stdlib flags needed — `./ocamlc -config` already points `standard_library` at
`_install/lib/ocaml`, whose `stdlib.cmi` is identical to the one in `stdlib/`.

**Do not use `_install/bin/ocamlc*`.** `_install/` is committed junk (see Repo hygiene);
its binaries have shebangs pointing at paths that don't exist on this machine.

**Trap once the C path lands:** emitted bytecode gets the header
`#!/home/ubuntu/jsip_debugger/_install/bin/ocamlrun-d104`. That committed runtime has
**zero** occurrences of `caml_wire_emit`, while the freshly built `runtime/ocamlrun` has
four. So after a successful rebuild you must either `make install` or link with
`-use-runtime runtime/ocamlrun`, or the program dies with
`unavailable primitive caml_wire_emit`.

### Testsuite

```sh
make -C testsuite parallel                  # everything, faster
make -C testsuite one DIR=tests/<area>      # one directory
```

The project has added **no tests** — `-visual-replay` is entirely untested by the
testsuite. `grep -rl 'vreplay\|wire_emit' testsuite/` returns nothing.

---

## Known broken — read this before debugging anything

**1. `ocamlc` silently stops relinking.** `Makefile:91-92` puts `snapshot.mli
snapshot.ml` inside `parsing_SOURCES`, which is wrapped in `$(addprefix parsing/, …)` —
but there is no `parsing/snapshot.ml`; the files live at `typing/snapshot.{ml,mli}`.
Confirm with:

```sh
strings compilerlibs/ocamlcommon.cma | grep -c '^Snapshot$'   # 0 == broken
```

Contrast `Makefile:174`, which lists `vreplay_instrumentation.{mli,ml}` *without* a
`typing/` prefix and is **fine** — `VPATH` (`Makefile:37`) includes `typing`. The
`parsing/` case is not saved by VPATH because the prerequisite has an explicit directory
component.

**2. `wire_external` is not reachable from where it's used.** It is defined at
`typing/vreplay_instrumentation.ml:11`, i.e. *inside* `module Wire`, but
`inject_instrumentation` at the bottom of the file refers to it unqualified — and the
`.mli` doesn't export it either. Any edit that splices it into the structure must
qualify it as `Wire.wire_external` (or move it out of the module).

**3. The sexp path is blocked.** `[@@deriving sexp]` (line 8) and
`Sexplib.Sexp.to_string_hum` (line 86, currently commented out) require ppx_sexp_conv /
sexplib, which the **compiler build does not have and cannot easily get** — the compiler
bootstraps against its own stdlib, not opam. This is why `print_call_node` is commented
out and why injection hardcodes a literal at line 191:
`~inject:(call_c_node "meow")`. Solving this is the main blocker on the compiler side.

**4. `filter_func` is a stub.** `typing/vreplay_instrumentation.ml:180` returns `true`
unconditionally, so *every* function application is instrumented. The intended behavior
is to fire only on data-structure creation/manipulation (see `vreplay/README.md`).
Likewise `let snapshot _x _y _z = _x` (line 51) is an identity-function placeholder.

**5. The `-visual-replay` help text is mangled.** `driver/main_args.ml:698-700` has a
literal newline inside the string, so `./ocamlc -help` prints it across two lines.

**6. `test_programs/map_test.ml` cannot be built here.** It opens `Base`, which exists
only in opam switches whose CMI magic (`Caml1999I578`) is incompatible with this
compiler's (`Caml1999I038`). No Base/Core is vendored. Use `.tmp_files/tmp.ml` instead.

---

## The wire format contract

**The two repos currently disagree, and this is the single most important thing to know
before touching serialization.**

### What the interface actually parses today

Line-based text via `Scanf.sscanf` — **not sexp, not JSON**. From
`~/jsip-debugger-interface/lib/parsing/src/dump_reader.ml` (branch `origin/parsing`):

```
:111   "%[^F]FUNCTION(%[^)]) ARGUMENTS(%[^)]) LOCATION(%[^)])"
:10    "%[^:]:[%[^]]]"                             -> lowercase tags: function_name | unnamed
:28    "LABEL:[{%[^}]}{%[^}]}] ARGUMENT:[%[^]]]"   -> args split on ';'
:76    "File %[^,], line %d, characters %d-%d"
```

The `%[^F]` prefix on the top-level line is a **brace depth delta**: each `{` is +1, each
`}` is −1, tracked across lines to reconstruct call nesting. The dump must end with a
line that returns depth to 0 or the reader raises. It reads a **file path**, never stdin:
`read_until_empty : string -> store_data:(Call.Info.t -> unit) -> unit`.

Reference fixture: `~/jsip-debugger-interface/app/bin/dummy.txt`.

### Where this is going

**Sexp is the intended direction.** `typing/vreplay_instrumentation.ml:2-8` defines the
target record:

```ocaml
type t =
  { location        : string
  ; function_type   : string
  ; function_data   : string
  ; argument_list   : (string * string) list }
[@@deriving sexp]
```

Getting there requires, in order:

1. **Unblock serialization without sexplib** (Known broken #3) — either hand-write an
   s-expression printer using only the compiler's own stdlib, or reuse
   `Misc`/`Format`-based printing. Do not add an opam dependency to the compiler build.
2. **Rewrite `dump_reader.ml` on the interface side** to parse sexp into
   `Call.Info.t = { depth; function_info; location; arguments }`
   (`~/jsip-debugger-interface/lib/types/src/call.ml:3-10`). The interface has no sexp
   reader for this today.
3. **Decide how depth is carried.** The current line format encodes it in `{`/`}` brace
   deltas emitted by separate `Printf.printf` calls; a sexp record has no equivalent, so
   depth must become an explicit field or stay as brace framing around each sexp.

### Mismatches to fix when you get there

- `Wire.format_function_call` emits capitalized `"Function_name"` / `"Unnamed"`
  (`typing/vreplay_instrumentation.ml:27-28`); the parser only accepts lowercase.
- `runtime/snapshot.c:8` prefixes every line with `[wire] `, which no parser strips.
  Either drop it or make it part of the documented framing.
- Brackets are emitted via `Printf.printf` from injected OCaml while the payload goes
  through the C stub — two different write paths into the same stream, easy to interleave
  wrongly.

---

## Conventions

**Style is enforced by `tools/check-typo`,** and every file this project added currently
fails it. Before committing:

```sh
./tools/check-typo-since trunk      # checks only changed files; instant
```

Hard rules (`CONTRIBUTING.md:119-122`): no trailing whitespace, no lines over 80 columns,
no tabs, ASCII only, newline at EOF. New `.ml`/`.mli`/`.c` files need the standard OCaml
license header — copy the 14-line block from `typing/typecore.ml:1-14`. (`.md` files are
exempt via `.gitattributes:63-67`.)

**Do not add `Changes` entries.** Upstream requires one per PR, but enforcement is gated
on upstream's PR flow and is meaningless for this fork.

**Do not modify upstream files** unless the feature genuinely requires it. Several
accidental reformats are already committed (see below); don't add more. In particular
avoid editor format-on-save in `runtime/`, `parsing/`, and the root `dune`.

### Branches

| Branch | What it is |
|---|---|
| `trunk` | **Pure upstream**, exactly `511483454`. Read-only reference / fork point. |
| `sexp_pipe` | **The integration tip — work here.** |
| `vreplay-main`, `runtime-memory` | Stale duplicates, both at `ff43cdaa0`, 7 commits behind. |
| `print_ast_node` (local) | Has 3 commits not merged anywhere. |

Commit style is informal and mixed (`feat:`/`fix:` alongside freeform). Match whatever
the surrounding history does; don't impose a convention.

### Worktrees

Several people and agents work this repo in parallel, so worktrees are common. Keep them
in one place: **`.worktrees/<name>`**, which is already gitignored (`.gitignore:334`).

```sh
git worktree add .worktrees/<name> -b <branch> HEAD
```

**Branch from `HEAD` (or `sexp_pipe`), not `trunk`.** `trunk` is pure upstream — a
worktree based on it has none of the project's files, which is a confusing five minutes
if you don't expect it.

Two caveats:

- Claude Code's own `EnterWorktree` tool creates worktrees under `.claude/worktrees/`
  instead, and that path is not configurable without `WorktreeCreate` hooks. Expect to
  see both locations; it's not a mistake.
- The git stash stack is **shared across all worktrees**. Never use bare `git stash` /
  `git stash pop` — you can pop someone else's work. Use a WIP commit, or
  `git stash push -m "<unique-tag>"` and `git stash apply <sha>`.

Run `git worktree list` before creating one, and `git worktree prune` if you see an entry
marked `prunable` (a registration whose directory was moved or deleted).

---

## Repo hygiene — why `git status` and `git diff` look insane

- **`_install/` is `make install` output and is no longer tracked.** It was committed by
  accident in `610a1c933` — 228 files, ~364,000 lines, about 97% of this fork's entire
  diff against upstream — and has since been untracked and gitignored. **The directory
  must still exist on disk**: `./ocamlc -config` reports `_install/lib/ocaml` as its
  `standard_library`. If it goes missing, recreate it with `make install`; never check it
  back in. Note it remains in git *history*, so `git log`/`git clone` size still reflect
  it, and a raw `git diff` against a pre-cleanup commit will still show all 228 files.
- `lambda/matching.cmt4e44c0.tmp` — 0-byte compiler temp file, committed by accident.
- **`runtime/caml/mlvalues.h`'s 507-line diff is a pure no-op reformat** (brace style +
  macro line rejoining). No token changed. Not project work.
- `parsing/parsetree.mli`'s 1-line diff *corrupts the license header*
  (`projet` → `project`) and breaks its column alignment. Not project work.
- `parsing/ast_helper.ml`'s +3 lines are trailing whitespace only.
- `parsing/dune`, root `dune`, `dune-project` diffs are ~99% `dune fmt` noise; only two
  real lines (adding `snapshot` and `vreplay` to module lists).
- `.tmp_files/` is the authors' gitignored scratch area — `tmp.ml` is the working test
  input, `*_dump.txt` are captured program stdout.

Apart from `_install/`, none of the above has been cleaned up. Just don't mistake it for
signal.

---

## Further reading

- **`README_C_Contributions.md`** — genuinely excellent 450-line in-repo guide to writing
  C in this tree: the `CAMLparam`/`CAMLlocal`/`CAMLreturn` GC contract, primitive
  registration, tag tables, debugging with `-runtime-variant d` and
  `OCAMLRUNPARAM='s=4k'`. **Read it before touching `runtime/`.**
- `HACKING.adoc` — upstream's build/dev guide.
- `README_vreplay.md` — **stale, do not follow.** It says the code lives in `parsing/`
  (it moved to `typing/` in `964b88231`) and gives an invocation that no longer works.
