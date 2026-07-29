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
| `parsing/snapshot.ml` / `.mli` | `external emit : string -> unit = "caml_wire_emit"`. **Nothing references it** — the mapper splices its own `external` into each instrumented unit. Kept deliberately; see `REVIEW_FINDINGS.md` #5. |
| `runtime/snapshot.c` | Defines `caml_wire_emit`. Writes its argument to stdout **verbatim** and flushes — no prefix, no added newline. Framing is the OCaml side's job. |
| `utils/clflags.ml:255`, `.mli:225` | `let visual_replay = ref false` |
| `driver/main_args.ml:698` + 5 module lists | `-visual-replay` flag wiring. |
| `Makefile:92`, `:174`, `:1251` | Build wiring for the above. |
| `vreplay/` | **Empty stubs.** `vreplay.ml`/`.c` are 0 bytes; `vreplay.mli` is prose pseudocode, **not valid OCaml** — and it *is* listed in the root `dune`, so `dune build` cannot succeed. Not built by `make`. |
| `test_programs/map_test.ml` | Test input — **cannot be compiled by this tree** (see below). |
| `REVIEW_FINDINGS.md` | Standing list of known bugs and open design decisions, with repros. Read it before starting on the wire format. |

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

**Always confirm the build actually relinked:**

```sh
ls -la --time-style=full-iso ocamlc driver/compile_common.cmo
# ocamlc must be NEWER than the .cmo, or your change is not in the binary
```

**`make -j world` races on a from-scratch tree** (e.g. a fresh worktree). Once `LINKC
ocamlc` starts, a concurrent job in `debugger/` or `ocamltest/` tries to run `./ocamlc`
mid-link and dies with `the file './ocamlc' is not a bytecode executable file`,
surfacing as `Error 127`. `-j 2` hits it too. It is transient, not a real failure —
finish with a **serial `make world`**, which is fast at that point because everything up
to `ocamlc` is already built. Incremental `-j` builds on an already-populated tree are
fine.

Also note `.depend` is tracked and currently **stale** (it still lists a
`parsing/vreplay` module that moved to `typing/` in `a39aa82fb`). It is `include`d by
the Makefile, so make remakes it whenever it looks out of date — in the main checkout
even `make -n` was enough — and it then shows up modified in `git status`. That is
expected, not your change. `make depend` and commit it once to be rid of it.

---

## Run the feature end to end

```sh
./ocamlc -visual-replay ./.tmp_files/tmp.ml    # writes ./a.out
./a.out
```

`.tmp_files/tmp.ml` is the authors' scratch file and its contents change often, so it is
a poor thing to check expected output against. For a stable smoke test use a snippet
whose call count you know:

```sh
printf 'let g x = x + 1\nlet f x = x + 2\nlet () = ignore (f (g 1))\n' > /tmp/t.ml
./ocamlc -visual-replay -o /tmp/t.out /tmp/t.ml && /tmp/t.out
```

Five applications execute — `ignore`, `f`, `g` and the two `+` — so the dump has five
frames and must end at depth 0. One record per line, each prefixed by the frame markers
giving its depth delta (`{` is +1, `}` is −1); the payload is still the literal `meow`:

```
{meow
{meow
{meow
{meow
}}{meow
}}}
```

**All of that goes through `caml_wire_emit`**, markers included. Do not reintroduce
`Printf.printf` for the markers: it writes into OCaml's stdout *channel* buffer, which
is only flushed at exit, while `caml_wire_emit` flushes on every call — mixing the two
put every marker in the run after every payload. See `REVIEW_FINDINGS.md` #2.

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

`REVIEW_FINDINGS.md` is the full list, with repros and status. The short version:

**1. An exception unbalances the dump.** The closing `}` is emitted as a *following*
let-binding, so a call that raises never closes its frame. `dump_reader.ml` raises on a
dump that doesn't return to depth 0, so any program using exceptions for control flow
(`Not_found`, `Exit`, …) produces an unreadable dump. Reproduce with a `try ... with`
around an instrumented call: the dump ends `{{{CAUGHT}`. The recommended fix is to carry
depth as an explicit field and drop closing markers entirely — see `REVIEW_FINDINGS.md`
#3, which also explains why re-raising from a `Texp_try` is the wrong first move (it
corrupts the user program's backtraces).

**2. The sexp path is blocked.** `[@@deriving sexp]` and the commented-out
`Sexplib.Sexp.to_string_hum` require ppx_sexp_conv / sexplib, which the **compiler build
does not have and cannot easily get** — the compiler bootstraps against its own stdlib,
not opam. Without ppx the attribute is *silently ignored*: there is no `sexp_of_t`
(zero occurrences in the `.cmi`). This is why `print_call_node` is commented out and why
injection hardcodes `placeholder_record = "meow\n"`. Solving it is the main blocker on
the compiler side.

Note `inject_then_run_node` takes `~inject` as an **arbitrary already-typed unit
expression** and knows nothing about what it does — the real instrumentation will be a
good deal more than one `caml_wire_emit` call (traversing argument values, allocating,
several writes). Keep it that way; don't push string-payload assumptions back into it.
It owns only the `{}` markers. Terminating a record with a newline is `~inject`'s job.

**3. `filter_func` is a stub.** It returns `true` unconditionally, so *every* function
application is instrumented, `+` and `^` included. The intended behavior is to fire only
on data-structure creation/manipulation (see `vreplay/README.md`). Now that every marker
is an unbuffered flushing write, this costs real time as well as noise.

**4. The `-visual-replay` help text is mangled.** `driver/main_args.ml:698-700` has a
literal newline inside the string, so `./ocamlc -help` prints it across two lines.

**5. `-visual-replay` is a silent no-op in the toplevel.** The flag is registered in all
four frontends, but `toplevel/` never goes through `compile_common` — it types phrases
via `Typemod.type_toplevel_phrase` (`toplevel/topcommon.ml:210`). So `ocaml
-visual-replay` accepts the flag and does nothing.

**6. `dune build` cannot succeed.** `vreplay/vreplay.mli` is prose, not OCaml
(`./ocamlc -stop-after parsing vreplay/vreplay.mli` → `Error: Syntax error`), and it is
listed in the root `dune`. Conversely `vreplay_instrumentation` is in **no** dune file,
so Merlin can't see the one file you actually edit. Since dune is only a Merlin helper
here, that's backwards.

**7. `test_programs/map_test.ml` cannot be built here.** It opens `Base`, which exists
only in opam switches whose CMI magic (`Caml1999I578`) is incompatible with this
compiler's (`Caml1999I038`). No Base/Core is vendored. Use `.tmp_files/tmp.ml` instead.
It is also wired into no test runner and its `| Add a, p ->` pattern doesn't match its
own `action` type.

### Fixed — don't go looking for these

Both of the long-standing build traps are gone as of `e6b9433cb`:

- *`ocamlc` silently stops relinking.* `snapshot.{ml,mli}` moved to `parsing/`, so the
  `$(addprefix parsing/, …)` in `parsing_SOURCES` (`Makefile:92`) is now correct.
  **The check this file used to recommend gives a false negative:**
  `strings compilerlibs/ocamlcommon.cma | grep -c '^Snapshot$'` still returns 0. Use
  `./tools/ocamlobjinfo compilerlibs/ocamlcommon.cma | grep Snapshot` instead, which
  reports `Unit name: Snapshot`.
- *`wire_external` unreachable.* It now lives at the top level of
  `vreplay_instrumentation.ml`, outside `module Wire`.

Also verified working, so don't re-derive it: prepending the `Tstr_primitive` does
**not** break module coercion when the unit has an `.mli` — tested with a module hiding
a value, linked against a second unit.

Note `parsing/snapshot.ml` is dead: nothing references `Snapshot.`, and what actually
makes `caml_wire_emit` available to instrumented programs is `runtime/snapshot.c` being
in `runtime_COMMON_C_SOURCES` (`Makefile:1251`), which puts the symbol in
`runtime/primitives`. It is kept deliberately; see `REVIEW_FINDINGS.md` #5.

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
3. **Decide how depth is carried.** The line format encodes it in `{`/`}` deltas; a sexp
   record has no equivalent, so depth must become an explicit field or stay as framing
   around each sexp. **Recommendation: make it an explicit field.** That is also the fix
   for the exception bug (Known broken #1) — if each record states its own depth, a dump
   truncated by an unwind is still well formed, an unwind is just the next record's depth
   jumping backwards, and there is nothing to emit on the raising path at all. See
   `REVIEW_FINDINGS.md` #3.

### Mismatches to fix when you get there

- `Wire.format_function_call` emits capitalized `"Function_name"` / `"Unnamed"`; the
  parser only accepts lowercase.
- The payload is still the hardcoded literal `"meow"` — blocked on the sexp problem
  above.

Two mismatches that used to be listed here are **fixed**: `runtime/snapshot.c` no longer
prefixes lines with `[wire] ` (it writes verbatim), and the markers no longer take a
separate write path from the payload — everything goes through `caml_wire_emit`. The
dump now lands on the shape `dump_reader.ml` already expects: marker prefix, then the
payload, one record per line.

---

## Conventions

**Style is enforced by `tools/check-typo`.** Every file this project added still fails
it on `missing-header` — that one is an open attribution decision, not an oversight, and
`REVIEW_FINDINGS.md` #14 explains why it hasn't just been copied from `typecore.ml`.
Everything else (trailing whitespace, long lines, EOF newline) should be kept clean.
Before committing:

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
  accident in `610a1c933` — 228 files (220 text totalling ~61,000 lines, plus 8 binaries;
  43 MB), about 97% of this fork's entire diff against upstream — and has since been
  untracked and gitignored. **The directory
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
