# CLAUDE.md — jsip_debugger

## What this repo is

A **fork of the OCaml compiler** (fork point `511483454`, upstream 5.6.0+dev) carrying one
feature: a `-visual-replay` flag that injects instrumentation into an arbitrary OCaml
program at the **Typedtree** layer, so that running the compiled program dumps one sexp
event per tracked data-structure operation (Map/Set today), each carrying a walked
snapshot of the structure's in-memory shape.

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
| `typing/vreplay_instrumentation.ml` / `.mli` | **The heart.** A `Tast_mapper` that rewrites each `Texp_apply` that `classify` marks as a DS event: frame markers, result binding, and a post-call `Vreplay.snapshot` hand-off. |
| `driver/compile_common.ml:117` | The hookpoint — one line, pipes the typed AST through the mapper. |
| `parsing/snapshot.ml` / `.mli` | `external emit : string -> unit = "caml_wire_emit"`. **Nothing references it** — the mapper splices its own `external` into each instrumented unit. Kept deliberately; see `REVIEW_FINDINGS.md` #5. |
| `runtime/snapshot.c` | Defines `caml_wire_emit` (verbatim write + flush; framing is the OCaml side's job) and `caml_wire_traverse`, the no-allocation BFS walker that builds each event's `node` tree. |
| `vreplay/` | **The runtime library** linked into instrumented programs: `data_structure.{ml,mli}` (catalogue: `Map \| Set` + per-type labels/masks), `sexp.{ml,mli}` (sexp AST + printer/parser + the wire schema + `to_sexp`/`from_sexp`), `vreplay.{ml,mli}` (weak registry + `snapshot`, the injected entry point). Built by `make vreplay` (part of `all`) into `vreplay/vreplay.cma`. |
| `bytecomp/bytelink.ml:950`, `driver/compmisc.ml:46` | Flag-gated linking: `vreplay.cma` is prepended after `stdlib.cma`, and `+vreplay` joins the load path, only under `-visual-replay`. |
| `utils/clflags.ml:255`, `.mli:225` | `let visual_replay = ref false` |
| `driver/main_args.ml:698` + 5 module lists | `-visual-replay` flag wiring. |
| `Makefile:92`, `:174`, `:863`, `:1251` | Build wiring; `:863` is the `vreplay` library target. |
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
a poor thing to check expected output against. Since `classify` landed, only calls into
modules listed in its `ds_table` (currently `Map.Make` products) are instrumented, so
plain-function programs are the *negative* smoke test — their dump must be empty:

```sh
printf 'let g x = x + 1\nlet f x = x + 2\nlet () = ignore (f (g 1))\n' > /tmp/neg.ml
./ocamlc -visual-replay -o /tmp/neg.out /tmp/neg.ml && /tmp/neg.out | wc -c   # 0
```

The positive smoke test needs a Map program. Note `-I vreplay`: the injected call
references `Vreplay`, and while `compmisc` adds `+vreplay` to the load path, that
resolves under `standard_library`, where nothing installs the library — from the repo
root, `-I vreplay` covers both the cmi at typing and the cma at link:

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
./ocamlc -visual-replay -I vreplay -o /tmp/t.out /tmp/t.ml && /tmp/t.out
```

Three events fire — the two `M.add` and the `M.remove`; `empty` (an ident, not an
application), `find` (returns the value, not the map) and `ignore` (not a DS call)
don't. One event per line, prefixed by the frame markers giving its depth delta (`{` is
+1, `}` is −1). The payload is real: the `event` wrapper carries the root's registry
id, location, function name, the live weak registry as `(id address)` pairs (grows as
structures are tracked, drops entries the GC collected; addresses captured by the same
walk as the nodes), and `(snapshot ...)` — `Vreplay.to_sexp` of the
`{ ds_type; root_node }` record with the walked shape:

```
{(event (id 1) (loc "File \"/tmp/t.ml\", line 4, characters 10-23") (fn M.add)
   (registry ((1 0x7f...)))
   (snapshot ((ds_type Map) (root_node ((virtual_address 0x7f...)
     (block ((l (Int 0)) (v (String a)) (d (Int 1)) (r (Int 0))))
     (children ()))))))
}{(event (id 2) ... (registry ((1 0x7f...) (2 0x7f...))) ...)
}{(event (id 3) ... (fn M.remove) ...)
}
```

(each event is one line on the wire; wrapped here for reading)

**All of that goes through `caml_wire_emit`**, markers included. Do not reintroduce
`Printf.printf` for the markers: it writes into OCaml's stdout *channel* buffer, which
is only flushed at exit, while `caml_wire_emit` flushes on every call — mixing the two
put every marker in the run after every payload. See `REVIEW_FINDINGS.md` #2.

No `-I` or stdlib flags needed — `./ocamlc -config` already points `standard_library` at
`_install/lib/ocaml`, whose `stdlib.cmi` is identical to the one in `stdlib/`.

**Do not use `_install/bin/ocamlc*`.** `_install/` is committed junk (see Repo hygiene);
its binaries have shebangs pointing at paths that don't exist on this machine.

**Trap:** emitted bytecode gets the header
`#!/home/ubuntu/jsip_debugger/_install/bin/ocamlrun-d104`. That committed runtime has
**zero** occurrences of `caml_wire_emit` or `caml_wire_traverse`, both of which every
instrumented program now needs. So after a successful rebuild you must either
`make install` or link with `-use-runtime runtime/ocamlrun`, or the program dies with
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

**2. The sexp path — unblocked.** Serialization no longer waits on sexplib:
`vreplay/sexp.ml` hand-rolls the s-expression AST, a sexplib-compatible printer/parser,
the wire schema, and `to_sexp`/`from_sexp` (following `[@@deriving sexp]` conventions,
so the interface repo can mirror the type definitions with ppx_sexp_conv and derive its
reader). The payload each event emits is real — `placeholder_record`/`meow` are gone.
Two residues: the `[@@deriving sexp]` on `Wire.t` is still *silently ignored* (no ppx in
the compiler build; never rely on it), and `Wire.argument_list` is computed but not yet
on the wire.

Note `instrument_call` (formerly `inject_then_run_node`) takes `?inject_before` and
`?inject_after` as closures producing **arbitrary already-typed expressions** and knows
nothing about what they do. Keep it that way; don't push payload assumptions back into
it. It owns only the `{}` markers; everything else, record newlines included, belongs to
the hooks.

**3. Filtering — fixed.** `filter_func` (which returned `true` unconditionally) is now
`classify`: an application is an event iff its function *and* its result type's head
constructor were declared in a compilation unit listed in `ds_table` — provenance read
off `val_uid`/`type_uid`, which survives `Map.Make` application, `open`, `include` and
aliasing. Each event runs a post-call `~inject_after` hook, sequenced between the result
binding and the closing `}`, which types a real `Vreplay.snapshot ~loc ~fn ~ds <root>`
call — the hand-off into the runtime's weak registry and C walker. `ds_table` covers
`Stdlib__Map`/`Set` (immutable, root = the result) and
`Stdlib__Hashtbl`/`Queue`/`Stack` (mutable, root = the first structure-typed ident
argument, read post-call; reads like `find`/`iter` fire too by design). The runtime
catalogue (`Data_structure`) only has Map/Set layouts today, so mutable-module events
fire but no-op at runtime — markers with no record. `list`/`array` have predef type
constructors and are still uncovered. See `REVIEW_FINDINGS.md` #12 for details and the
accepted misses.

**4. The `-visual-replay` help text is mangled.** `driver/main_args.ml:698-700` has a
literal newline inside the string, so `./ocamlc -help` prints it across two lines.

**5. `-visual-replay` is a silent no-op in the toplevel.** The flag is registered in all
four frontends, but `toplevel/` never goes through `compile_common` — it types phrases
via `Typemod.type_toplevel_phrase` (`toplevel/topcommon.ml:210`). So `ocaml
-visual-replay` accepts the flag and does nothing.

**6. `dune build` cannot succeed.** The root `dune` still lists a `vreplay` module from
the stub era, and none of the files actually edited — `vreplay_instrumentation`, the
`vreplay/` library trio — appear in **any** dune file, so Merlin/ocamllsp report "No
config found" on exactly the files this project works on. Since dune is only a Merlin
helper here, that's backwards. (The old "`vreplay.mli` is prose → syntax error" claim
is gone: the file is real OCaml now.)

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

### What the compiler emits today

**Sexp landed on the compiler side.** Each event is one line,

```
(event (id N) (loc "File ...") (fn M.add)
  (registry ((1 0x..) (2 0x..))) (snapshot <payload>))
```

where `(registry ...)` is the live weak registry — every tracked-and-alive structure
as an `(id current-address)` pair, captured by the same C walk as the nodes so an
`(Address a)` inside the snapshot resolves against it exactly — and `<payload>` is
`Vreplay.to_sexp` of the wire record (defined in `vreplay/sexp.ml`, re-exported by
`Vreplay`):

```ocaml
type t = { ds_type : Data_structure.t; root_node : node }
type node = { virtual_address : nativeint
            ; block : (string * block) list   (* Int/Float/String/... *)
            ; children : node list }
```

`to_sexp`/`from_sexp` follow `[@@deriving sexp]` conventions — records as
`((field value) ...)`, constructors as `(Name arg)` — so the interface can mirror the
type definitions with ppx_sexp_conv and derive its reader. `Vreplay.from_sexp` +
`Sexp.of_string` in this repo are the reference reader (exact inverses of the
emitters). `module Wire` in the instrumentation now only supplies the `loc`/`fn`
strings on the event wrapper.

Remaining, in order:

1. **Rewrite `dump_reader.ml` on the interface side** to parse the event lines into
   `Call.Info.t = { depth; function_info; location; arguments }`
   (`~/jsip-debugger-interface/lib/types/src/call.ml:3-10`). The interface has no sexp
   reader for this today.
2. **Decide how depth is carried.** The line format encodes it in `{`/`}` deltas; a sexp
   record has no equivalent, so depth must become an explicit field or stay as framing
   around each sexp. **Recommendation: make it an explicit field.** That is also the fix
   for the exception bug (Known broken #1) — if each record states its own depth, a dump
   truncated by an unwind is still well formed, an unwind is just the next record's depth
   jumping backwards, and there is nothing to emit on the raising path at all. See
   `REVIEW_FINDINGS.md` #3.

### Mismatches to fix when you get there

- `dump_reader.ml` still scans the old `FUNCTION(...) ARGUMENTS(...) LOCATION(...)`
  line format; the compiler now emits the `(event ...)` sexp lines above. (The old
  capitalized `Function_name` mismatch is moot — `function_type` is not on the wire.)
- `Wire.argument_list` is computed but not emitted; arguments reach the wire only when
  someone threads them into the event wrapper.

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
| `vreplay-main` | Currently the same commit as `sexp_pipe` (it was fast-forwarded); still treat `sexp_pipe` as the PR base. |
| `runtime-memory` | Stale, at `ff43cdaa0`, behind the tip. |
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
