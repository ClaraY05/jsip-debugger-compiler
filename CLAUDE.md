# CLAUDE.md — jsip_debugger

## What this repo is

A **fork of the OCaml compiler** carrying one feature: a `-visual-replay`
flag that injects instrumentation into an arbitrary OCaml program at the
**Typedtree** layer, so that running the compiled program dumps one sexp
event per observed value — each call on a catalogued container (the stdlib's
`Map`/`Set`/`Queue`/`Hashtbl`/`Stack`/`Dynarray` and Base/Core's
equivalents) and each `let` of a value of the program's own declared types —
carrying a walked snapshot of that value's in-memory shape. See "What is
tracked" for the exact rules.

The tree sits on an **OCaml 5.5 base** — `VERSION` is `5.5.1+dev0-2026-06-19`
and the upstream commit under all project work is **`466e585663`**. It did
not start there: the fork point was `511483454` (5.6.0+dev), and
`ecb3981bb1` merged a replay of the whole branch onto 5.5. Two consequences:

- **`trunk` is no longer the base.** It still points at `511483454`, so
  `git diff trunk HEAD` mixes the project's work with the entire 5.5-vs-5.6
  upstream delta. To see project work vs upstream, diff against the real
  base: `git diff 466e585663 HEAD -- <path>` (103 files, ~6k lines, all of
  it project work).
- Most commits appear twice in `git log --all` — once on the 5.6 line, once
  replayed on 5.5. Only the 5.5 copies are ancestors of `vreplay-main`.

This is one half of a two-repo project:

```
jsip_debugger  (this repo)                  ~/jsip-debugger-interface
  instrumented ocamlc                         bonsai_term TUI
  ocamlc -visual-replay foo.ml                (GDB-style, steps through
  ./foo → vreplay.dump  ───────────────────→   the call stack, source,
          (one sexp event per line)            and heap shapes)
```

**You are almost always working on the compiler half.** The interface half
lives at `~/jsip-debugger-interface` (GitHub `wuad391/jsip-debugger-interface`,
branch `main`) and has its own `CLAUDE.md`. `~/jsip-visual-debugger` is a
dead scaffold — ignore it.

Goal of the project: visualize allocated data and data structures as the
user steps through a replay of their program — a TUI debugger that doesn't
require knowing assembly.

---

## Orient fast: the project's own files

This tree is ~1M lines of upstream OCaml. **Everything the project actually
wrote is this list.** If you are grepping the whole tree, you are probably
lost. (Line numbers drift; the symbol names don't.)

| File | Role |
|---|---|
| `typing/vreplay_instrumentation.ml` / `.mli` | **The heart.** A `Tast_mapper` that rewrites each `Texp_apply` that `classify` marks as a DS event: frame markers, result binding, payload schemas derived from the user's type declarations, and a post-call `Vreplay.snapshot` hand-off. |
| `driver/compile_common.ml:97` | The hookpoint — one line, pipes the typed AST through the mapper. |
| `runtime/snapshot.c` | Defines `caml_wire_emit` (writes to the dump sink; framing is the OCaml side's job) and `caml_wire_traverse`, the no-allocation BFS walker that builds each event's `node` tree. |
| `vreplay/` | **The runtime library** linked into instrumented programs: `data_structure.{ml,mli}` (the catalogue: which DSs are walkable and their per-layer interior/payload layouts), `sexp.{ml,mli}` (sexp AST + printer/parser + **the wire schema** + `to_sexp`/`from_sexp`), `vreplay.{ml,mli}` (weak registry, dump sink, and `snapshot`, the injected entry point). Built by `make vreplay` (part of `world`) into `vreplay/vreplay.cma`. |
| `bytecomp/bytelink.ml:935`, `asmcomp/asmlink.ml:349`, `driver/compmisc.ml:48` | Flag-gated linking: `vreplay.cma` / `vreplay.cmxa` is prepended after the stdlib archive, and `+vreplay` joins the load path, only under `-visual-replay`. |
| `utils/clflags.ml:253`, `.mli:221` | `let visual_replay = ref false` |
| `driver/main_args.ml:692` + 5 module lists | `-visual-replay` flag wiring. |
| `Makefile:92`, `:172`, `:872`, `:1299` | Build wiring; `:872` is the `vreplay` library target, `:1299` puts `snapshot` in `runtime_COMMON_C_SOURCES`. |
| `parsing/snapshot.ml` / `.mli` | `external emit : string -> unit = "caml_wire_emit"`. **Nothing references it** — the mapper splices its own `external` into each instrumented unit, and what actually makes the primitive available is `runtime/snapshot.c` being in `runtime_COMMON_C_SOURCES`. Kept deliberately. |
| `testing/` | The project's own test suite: golden dumps, their programs, and `check_dump.ml`. See `testing/README.md`. |
| `test_programs/map_test.ml` | Stale scratch input, wired into no runner, and its `\| Add a, p ->` pattern doesn't match its own `action` type. Use `testing/cases/` or `.tmp_files/tmp.ml` instead. |

**`REVIEW_FINDINGS.md` no longer exists** (deleted in `ff240449a1`). Several
in-repo docs still cite it by number — `testing/README.md` mentions
"REVIEW_FINDINGS #3" for the exception bug. Those are dangling references;
the live summary is "Known broken" below.

---

## Build

**`make` is the live build system. Dune is not.** Dune exists here only as a
Merlin helper (`HACKING.adoc:518`) and currently cannot even configure — see
Known broken #4. Ignore `_build/`.

A **fresh worktree has no `Makefile.config`** and must be configured once
before anything else:

```sh
./configure --prefix=$PWD/_install
```

Then:

```sh
make -j4 world         # full/incremental build (bytecode). This machine has 4 cores.
```

- **Native is supported too.** `make world` is bytecode only; a follow-up
  `make -j4 opt` adds `ocamlopt`, the native runtime/libraries, and
  `vreplay/vreplay.cmxa`, after which `-visual-replay` links its runtime
  into native executables as well. The instrumentation itself is shared
  (`compile_common` feeds both backends), so bytecode-only work still only
  needs `make world`.
- After editing anything in `typing/`, `driver/`, `utils/`, or a `.c` in
  `runtime/`: just `make -j4 world`. `runtime/primitives` and
  `runtime/prims.c` are regenerated automatically. Only
  `rm runtime/primitives runtime/prims.c` if you **added a new primitive
  name** and hit a phantom "unavailable primitive" error.
- **`make bootstrap` is not needed** for this project's kind of change.
- Adding a new `.c` file to the runtime means adding its stem to
  `runtime_COMMON_C_SOURCES` (`Makefile:1252`).

**`make -j` races on a from-scratch tree** (e.g. a fresh worktree). Once
`LINKC ocamlc` starts, a concurrent job in `debugger/` or `ocamltest/` tries
to run `./ocamlc` mid-link and dies with `the file './ocamlc' is not a
bytecode executable file`, surfacing as `Error 127`. `-j 2` hits it too. It
is transient, not a real failure — finish with a **serial `make world`**,
which is fast at that point because everything up to `ocamlc` is already
built. Incremental `-j` builds on an already-populated tree are fine.

**Always confirm the build actually relinked, and that the binary matches
the tree:**

```sh
ls -la --time-style=full-iso ocamlc driver/compile_common.cmo
# ocamlc must be NEWER than the .cmo, or your change is not in the binary
runtime/ocamlrun ./ocamlc -config | grep '^version'
# must match VERSION -- a binary reporting 5.6.0+dev predates the 5.5 rebase
```

That last check matters: a long-lived checkout can hold an `ocamlc` built
before `ecb3981bb1` while the sources are on 5.5. Rebuild before trusting it.

`.depend` is tracked and can go stale. It is `include`d by the Makefile, so
make remakes it whenever it looks out of date — even `make -n` is enough —
and it then shows up modified in `git status`. That is expected, not your
change. `make depend` and commit it once to be rid of it.

---

## Run the feature end to end

**Every bytecode tool in this tree must be run under `runtime/ocamlrun`.**
A bare `./ocamlc`, `./tools/ocamlobjinfo`, … dies on its shebang with
`cannot execute: required file not found`, and because that is a shell
failure rather than a tool error it usually shows up as *empty output* —
which reads as a real answer and sends you debugging the wrong thing.
Prefix everything:

```sh
runtime/ocamlrun ./ocamlc -config
runtime/ocamlrun ./tools/ocamlobjinfo compilerlibs/ocamlcommon.cma
```

For compiling, also note that depending on how the tree was configured
`standard_library` may point somewhere unpopulated, so use the
config-independent invocation (`TEST.README.md` has the long-form version,
verified in-tree):

```sh
runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay -visual-replay \
  -use-runtime $PWD/runtime/ocamlrun -o /tmp/t.out /tmp/t.ml
```

`-I vreplay` is needed because the injected call references `Vreplay`: while
`compmisc` adds `+vreplay` to the load path, that resolves under
`standard_library`, where nothing installs the library from a plain build.
`-use-runtime` is needed because the shipped runtime does not export
`caml_wire_emit` / `caml_wire_traverse`; without it the program dies with
`unavailable primitive caml_wire_emit`.

The native equivalent (needs `make opt` to have run; `ocamlopt` is itself
a bytecode executable, so it too runs under `runtime/ocamlrun`):

```sh
runtime/ocamlrun ./ocamlopt -nostdlib -I stdlib -I vreplay -visual-replay \
  -o /tmp/t.out /tmp/t.ml
```

No `-use-runtime` here: a native executable links `libasmrun.a` from this
tree, which already carries `snapshot.o` (`runtime_COMMON_C_SOURCES` feeds
both runtimes), so `caml_wire_emit`/`caml_wire_traverse` resolve at C link
time. The flip side: linking an instrumented program against a stock
`libasmrun` fails at link time with undefined-symbol errors for those two —
the native analogue of bytecode's "unavailable primitive".

`_install/` currently holds only `lib/ocaml` in both checkouts — there is no
`_install/bin` unless someone runs `make install`, and if they do, prefer
the invocation above to the installed binaries anyway (their shebangs point
at whatever path the tree was configured with).

### Where the dump goes — *not* stdout

The instrumented program picks its sink at the first event, from the
environment (`vreplay/vreplay.ml`; `README_vreplay.md` documents it):

- `VREPLAY_SOCK=<path>` — connect a Unix domain stream socket (a live
  listener, e.g. the debugger interface). A failed connect warns on stderr
  and falls through to the file sink.
- `VREPLAY_FILE=<path>` — write that file, truncated at start.
- neither — write `./vreplay.dump`.

The dump never goes to stdout, so the program's own printing cannot corrupt
it. If the sink cannot be opened, a one-line warning goes to stderr and
emission is disabled; the program keeps running.

**Everything goes through `caml_wire_emit`**, `{`/`}` markers included. Do
not reintroduce `Printf.printf` for the markers: it writes into OCaml's
stdout *channel* buffer, flushed only at exit, while `caml_wire_emit`
flushes on every call — mixing the two put every marker in the run after
every payload.

### Smoke tests

Negative — a plain-function program must produce no events. The sink is
opened lazily at the *first* event, so a clean negative leaves **no dump
file at all**, not an empty one:

```sh
printf 'let g x = x + 1\nlet f x = x + 2\nlet () = ignore (f (g 1))\n' > /tmp/neg.ml
runtime/ocamlrun ./ocamlc -nostdlib -I stdlib -I vreplay -visual-replay \
  -use-runtime $PWD/runtime/ocamlrun -o /tmp/neg.out /tmp/neg.ml
rm -f /tmp/neg.dump
VREPLAY_FILE=/tmp/neg.dump /tmp/neg.out
test ! -e /tmp/neg.dump && echo "no events, as expected"
```

(`testing/expected/neg_*.dump` are 0-byte files because `run_tests.sh:70`
truncates the dump into existence before the run; the runtime does not.)

Positive — a Map program. Three events fire (the two `M.add` and the
`M.remove`); `empty` is an ident not an application, `find` returns the
value not the map, and `ignore` is not a DS call:

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
VREPLAY_FILE=/tmp/t.dump /tmp/t.out && cat /tmp/t.dump
```

One event per line, prefixed by the frame markers giving its depth delta
(`{` is +1, `}` is −1). A call can emit **several** event records inside one
`{}` frame — one per root (mutated container arguments plus a structure
result). Real output, abridged and wrapped for reading:

```
{(event (id 1) (loc ((file_path /tmp/t.ml) (line_number 4) ...))
   (fn (Function_name M.add))
   (args ((No_label (expression (Unnamed "\"a\"")))
          (No_label (expression (Unnamed 1)))
          (No_label (expression (Unnamed m)))))
   (registry ((1 0x7c4dc23f2360 m)))
   (ty ((printed "int M.t") (params ((key string) (data int)))))
   (snapshot ((ds_type Map) (root_node ((id 1) (virtual_address 0x7c4d...)
     (block ((l (Int 0)) (v (String a)) (d (Int 1)) (r (Int 0))))
     (children ()))))))
}{(event (id 2) ... (registry ((1 0x7c4dc23f2360 m) (2 0x7c4dc23ee788 m)))
   (snapshot ((ds_type Map) (root_node ((id 2) ...
     (block ((l (Int 0)) (v (String a)) (d (Int 1)) (r Child)))
     (children (((id 3) ... (block ((l (Int 0)) (v (String b))
                                    (d (Int 2)) (r (Int 0))))
                 (children ())))))))))
}{(event (id 3) ... (fn (Function_name M.remove))
   (snapshot ((ds_type Map) (root_node ((id 3) (virtual_address 0x7c4d...)
     (block ()) (children ()))))))
}
```

That third record is the whole delta story in one line: `M.remove "a"` on
`{a; b}` returns the already-dumped `b` subtree, so instead of re-dumping it
the event collapses to a **revisit stub** — root id 3 (matching the node
event 2 defined), its current address, and empty `block`/`children`. Note
also `(r Child)` in event 2: the field is labeled in `block` and its value
is `children`'s next node.

### Tests

The project's own tests live in **`testing/`** — golden-dump cases plus a
structural checker. Run them after any change to the instrumentation, the
vreplay library, or `runtime/snapshot.c`:

```sh
testing/run_tests.sh              # everything (needs a built tree)
testing/run_tests.sh map_basic    # selected cases
testing/run_tests.sh --promote    # re-bless expected/ after a deliberate change
```

`check_dump` validates structure **before** the golden diff — wrapper
fields, sexp round-trip, depth balance, and the sharing invariants — so a
`--promote` only rewrites goldens that were already well formed. Addresses
are canonicalized for the comparison only, so goldens stay verbatim run
output and double as the interface repo's parser fixtures. `testing/README.md`
lists what the cases cover.

**`testing/mock/` is how the Base/Core cases run at all.** This tree has no
opam switch and no Core installed, so the suite compiles miniature stand-ins
that reuse the *real unit names and representations*
(`base__Map.ml`, `core__Deque.ml`, …) into a `mocks.cma` and compiles the
`core_*` cases against it. That is enough to exercise `ds_table`'s
provenance matching and the walker's layouts in CI. It is not enough to
prove anything about the genuine Core layouts — for that, use the
`jsip-vreplay` switch below. When you add a Core entry, add its mock unit
and its case together.

The upstream testsuite has **no** `-visual-replay` coverage:

```sh
make -C testsuite parallel                  # everything, faster
make -C testsuite one DIR=tests/<area>      # one directory
```

### The `jsip-vreplay` opam switch

`README_opam_switch.md` sets up a switch whose *compiler is this fork*, with
Base/Core/ppx_jane built against it (matching CMI magic by construction), so
`ocamlc -visual-replay` works as an ordinary installed compiler on real
Core-using programs. Bytecode-only by design. It takes ~1h to build; it is
the only way to check the Core catalogue entries against *real* Core layouts
rather than `testing/mock/`'s stand-ins. Needs at least `b3dd6d23a1` on the
branch.

---

## The wire format contract

**`vreplay/sexp.mli` is the spec — read it in full before changing anything
about serialization.** It is a prose specification as much as an interface:
the block-representation table, the delta/sharing rules, the registry
format, and the `ty` shape are all documented there.

Both sides derive from this one schema — no string parsing remains anywhere
— but **the interface trails the compiler by design**: a structure lands
here first, and the interface has to grow the matching `Ds_type`
constructor before it can read the newer dumps. As of 2026-08-03 its `main`
handles `Map`/`Set`/`Queue` while this repo emits fifteen `ds_type` names
(the six stdlib containers, eight Core/Base ones, and `User`). Assume a
freshly vendored dump needs interface work, not that it is broken.

Every event is one line:

```
(event (id N) (loc ...) (fn ...) (args ...) (registry ...) (ty ...) (snapshot ...))
```

- `loc` / `fn` / `args` are rendered in the shapes `[@@deriving sexp]` gives
  the **interface repo's own types** (`Location.t`, `Function_info.t`,
  `Argument.t` in `~/jsip-debugger-interface/lib/types`), so its reader is
  derived, not hand-written — see `Sexp.sexp_of_loc/fn/args`.
- `registry` is the live weak registry: `(id address)` or `(id address name)`
  per tracked-and-alive structure, captured by the same C walk as the nodes.
  The name is the latest non-empty identifier the structure was observed
  under (a `let` binder or a mutated container argument); anonymous entries
  keep the two-atom shape. Entries appear when a structure is first tracked
  and vanish once the GC collects it.
- `ty` carries the root's static type as printed off the typedtree, plus
  role-labeled parameters (`key`/`data` for maps and hashtables, `elt` for
  sets and queues), so the interface displays types without parsing OCaml.
- `snapshot` is `Vreplay.to_sexp` of `{ ds_type; root_node }`.

Two properties that are easy to get wrong:

1. **Dumps are deltas.** Every node carries a wire id unique across the
   dump. For immutable structures (Map/Set) a block is dumped **at most
   once**; every later occurrence is `(Id n)`, and a re-observed structure's
   whole event collapses to a **revisit stub** (root id, current address,
   empty `block` and `children`). Mutable structures (Queue/Hashtbl) re-walk
   in full each event, the root keeping its registry id while interior cells
   take fresh ids. A reader reconstructs any event by resolving `(Id n)`
   against the node that defined it earlier.
2. **Every kept field is labeled, in `block`.** A field whose value is a
   block of its own reads `Child` and stands for the next entry of
   `children`, in order. So a reader needs no layout table of its own — not
   for a user record's fields, not for which side (`l`/`r`) a map child hung
   off. Payload labels come from schemas the instrumentation derives from
   the user's own type declarations.

`Vreplay.from_sexp` + `Sexp.of_string` in this repo are the reference reader
and exact inverses of the emitters. `to_sexp`/`from_sexp` follow
`[@@deriving sexp]` conventions — records as `((field value) ...)`,
constructors as `(Name arg)` — so the interface mirrors the type definitions
with `ppx_sexp_conv`. **There is no ppx in the compiler build; never add
code that relies on one.**

On the interface side, `[@sexp.allow_extra_fields]` is set **only** on the
event wrapper, so adding a wrapper field is backward compatible while adding
a nested field is not. After any deliberate change: `run_tests.sh --promote`
here, then re-vendor `testing/` into the interface repo.

Note `instrument_call` takes `?inject_before` / `?inject_after` as closures
producing **arbitrary already-typed expressions** and knows nothing about
what they do. Keep it that way; don't push payload assumptions back into it.
It owns only the `{}` markers.

### What is tracked

Two different things produce events, and they are classified in different
places.

**1. Catalogued container calls.** `ds_table` in
`typing/vreplay_instrumentation.ml` maps a *declaring compilation unit* to
`(mutability, catalogue names)`; `vreplay/data_structure.mli` holds the
layouts. **Extend both together** — a unit named without a layout no-ops at
runtime, and a layout nothing maps to is dead.

| Catalogue entry | Declaring units | Root |
|---|---|---|
| `Map`, `Set` | `Stdlib__Map`, `Stdlib__Set` | immutable — the result |
| `Queue`, `Hashtbl`, `Stack`, `Dynarray` | the matching `Stdlib__*` | mutable — each structure-typed argument, read post-call (so `pop`/`peek` fire by design) |
| `Core_map`, `Core_set` | `Base__Map`, `Core__Map`, their `*_intf`, likewise for Set | immutable |
| `Core_hashtbl`, `Core_hash_set`, `Core_queue`, `Core_stack`, `Core_deque`, `Core_fdeque`, `Core_doubly_linked` | the matching `Base__*` / `Core__*` and their `*_intf` | mutable (`Core_fdeque` immutable) |

Two rules worth internalizing:

- **One catalogue entry per *representation*, not per module.** `Core.Map.t`
  is an alias of `Base.Map.t`, and `Map.Poly`, `Int.Map` and every `Make`
  instance are that same type, so one entry covers them all. Conversely
  `Core.Linked_queue` *is* `Stdlib.Queue.t`, so it belongs to `Queue` — which
  is why a unit maps to a *list* of names (`Base__Queue` → `Core_queue`,
  `Queue`).
- **The `*_intf` units matter.** Base/Core declare their types in
  `Base__Map_intf` rather than `Base__Map`, so omitting the `_intf` entry
  silently tracks nothing.

Classification is by **provenance**, not by name: an application is an event
iff its function *and* its result type's head constructor were declared in a
unit listed in `ds_table`, read off `val_uid`/`type_uid`, which survives
`Map.Make` application, `open`, `include` and aliasing. Functor parameters
and first-class modules fail closed.

`list`/`array` have predef type constructors and stay uncovered, on purpose.

**2. Values of the program's own types** (`ds_type User`). A `let` whose
bound expression's head type constructor was declared outside the stdlib is
an event in its own right — `let p = { x = 3; y = 4 }` dumps `p`, with no
container call anywhere in the file. `User` is not a container: it has an
empty `layout`, and its shape comes from the schema the instrumentation
derives from the user's type declaration rather than from a hand-written
layout. Three conditions, all deliberate:

- **A named binder.** The root is the `let`'s identifier; anonymous
  subexpressions and record fields emit nothing.
- **`is_user_declared` reads the type *without* `Ctype.expand_head`.**
  Expanding would follow an alias like `type trades = trade list` down to
  predef `list` and reject exactly the declarations worth observing. A bare
  tuple is not a `Tconstr` at all, so it never qualifies.
- **The schema must actually describe the type.** If `root_schema` yields no
  roles (a variant, an abstract type) the binding is skipped — an
  unlabeled block is no better than the numbering this replaces.

So bare `list`/`array`/tuple values are *contents, not subjects*: never
events themselves, drawn only when reached from something that is.
`testing/cases/user_types.ml` is the readable statement of all of this,
negatives included.

Because `User` is a `Data_structure.t` constructor, **the interface's
`Snapshot.Ds_type` has to grow it too** before it can read these dumps.

---

## Known broken

**1. An exception unbalances the dump.** The closing `}` is emitted as a
*following* let-binding, so a call that raises never closes its frame. The
interface's reader raises on a dump that doesn't return to depth 0, so any
program using exceptions for control flow (`Not_found`, `Exit`, …) produces
an unreadable dump. Reproduce with a `try ... with` around an instrumented
call. The recommended fix is to carry depth as an explicit event field and
drop closing markers entirely — a truncated dump is then still well formed
and an unwind is just the next record's depth jumping backwards. Re-raising
from a `Texp_try` is the wrong first move: it corrupts the user program's
backtraces. `testing/` deliberately has no case for this.

**2. The `-visual-replay` help text is mangled.** `driver/main_args.ml:693`
has a literal newline inside the string, so `ocamlc -help` prints it across
two lines, and the text itself ("Render the txt file for JSIP debugger
tool") no longer describes what the flag does.

**3. `-visual-replay` does not work in the toplevel.** The flag is
registered in all four frontends, but `toplevel/` never goes through
`compile_common` — it types phrases via `Typemod.type_toplevel_phrase`. So
`ocaml -visual-replay` / `ocamlnat -visual-replay` accept the flag without
instrumenting anything. No longer *silent*: since PR #16, `Toploop.prepare`
warns on stderr that the flag is ignored. Actual toplevel instrumentation
remains unimplemented.

**4. `dune build` cannot succeed.** The root `dune` still lists a `vreplay`
module from the stub era (`Error: Module Vreplay doesn't exist`), and none
of the files this project actually edits — `vreplay_instrumentation`, the
`vreplay/` library trio — appear in **any** dune file, so Merlin/ocamllsp
report "No config found" on exactly the files this project works on. Since
dune is only a Merlin helper here, that's backwards.

### Fixed — don't go looking for these

- *`ocamlc` silently stops relinking* (the `parsing_SOURCES` prefix bug).
  Two false negatives to avoid if you check whether a unit made it into the
  library: `strings compilerlibs/ocamlcommon.cma | grep -c '^Snapshot$'`
  returns 0 even when it is there, and a **bare** `./tools/ocamlobjinfo`
  dies on its shebang and prints nothing, which reads as "absent". The
  working form is
  `runtime/ocamlrun ./tools/ocamlobjinfo compilerlibs/ocamlcommon.cma | grep Snapshot`
  → `Unit name: Snapshot`.
- *`wire_external` unreachable.* It lives at the top level of
  `vreplay_instrumentation.ml` now.
- *The dump interleaving with the program's stdout.* Fixed by the dedicated
  sink; `testing/cases/stdout_mixed.ml` covers it.
- *Unfiltered instrumentation.* `filter_func` (which returned `true`
  unconditionally) became `classify`, described above.

Also verified working, so don't re-derive it: prepending the
`Tstr_primitive` does **not** break module coercion when the unit has an
`.mli` — tested with a module hiding a value, linked against a second unit.

---

## Conventions

### check-typo

**Style is enforced by `tools/check-typo`**, which CI runs over every file a
PR touches. Hard rules (`CONTRIBUTING.md:119-122`): no trailing whitespace,
no lines over 80 columns, no tabs, ASCII only, newline at EOF.

License headers: new `.ml`/`.mli`/`.c` files normally need the 14-line OCaml
block (copy it from `typing/typecore.ml:1-14`), but **this project's files
are exempted instead** — `.gitattributes:28-36` lists `/vreplay/*`,
`/runtime/snapshot.c`, both `vreplay_instrumentation` files and `/.claude/*`
as `typo.missing-header=may`. A new project file needs either the header or
a line there. `.md` files are exempt from the header, long-line and
non-ASCII checks (`.gitattributes:78,89`), and `testing/` is exempted where
it holds machine-written output (`.gitattributes:32-35`).

Before committing:

```sh
./tools/check-typo-since 466e585663    # the real upstream base, not trunk
```

**Use the base sha, not `trunk`.** Since the 5.5 rebase, diffing against
`trunk` drags in upstream files the project never touched
(`runtime/caml/mlvalues.h`, `build-aux/`, `Makefile`, …) and buries real
findings under inherited ones. Against `466e585663` the tree is currently
**clean** — any output is yours.

A `make distclean` that leaves files behind will fail CI's clean-tree check.

`runtime/*.c` must stay **MSVC-clean** (no `ssize_t`, no declarations after
statements in the old style, etc.). The Windows CI is four jobs: one real
compile failure plus three fail-fast cancellations, so read the first one.

### Pull requests

The repo was renamed on GitHub to **`ClaraY05/jsip-debugger-compiler`**. The
local `origin` still points at the old `ClaraY05/jsip_debugger.git`, so every
push prints `remote: This repository moved.` — harmless (GitHub redirects),
but use the new name in every `gh` command.

**Never open a PR against upstream `ocaml/ocaml`.** This is a fork and `gh`
will happily default to the parent. Always be explicit:

```sh
gh pr create --repo ClaraY05/jsip-debugger-compiler --base vreplay-main --draft
```

`gh pr edit` fails on a GraphQL `projectCards` deprecation. Use the API
directly instead:

```sh
gh api repos/ClaraY05/jsip-debugger-compiler/pulls/N -X PATCH -F body=@file
gh api repos/ClaraY05/jsip-debugger-compiler/issues/N/labels -X POST \
  -f 'labels[]=no-change-entry-needed'
```

**Every PR needs a `Changes` entry or the `no-change-entry-needed` label.**
The inherited `hygiene.yml` runs upstream's `check-changes-modified.sh` on
every PR, so it is enforced here even though the fork has no upstream
release notes. The label exists in the fork; applying it is usually the
right call.

**Do not modify upstream files** unless the feature genuinely requires it.
Several accidental reformats are already committed (see below); don't add
more. In particular avoid editor format-on-save in `runtime/`, `parsing/`,
and the root `dune`.

Commit style is informal and mixed (`feat:`/`fix:` alongside freeform).
Match whatever the surrounding history does; don't impose a convention.

### Branches

| Branch | What it is |
|---|---|
| `vreplay-main` | **The integration tip and the PR base.** Also the fork's default branch on GitHub. |
| `trunk` | Pure upstream at `511483454` (5.6.0+dev). Historical fork point only — **not** the current base; see the top of this file. |
| `feat/*`, `fix/*`, `tests/*` | One per PR. Several are open at any time. |

**A long-lived checkout is easily behind `origin/vreplay-main`.** Merged PRs
land on the remote; the local branch does not follow. `git fetch` and
compare before assuming your tree is the tip:

```sh
git rev-list --left-right --count vreplay-main...origin/vreplay-main
```

### Worktrees

Several people and agents work this repo in parallel, so worktrees are
common. Keep them in one place: **`.worktrees/<name>`**, which is already
gitignored.

```sh
git worktree add .worktrees/<name> -b <branch> origin/vreplay-main
```

**Branch from `origin/vreplay-main`, not `trunk`.** `trunk` is pure upstream
— a worktree based on it has none of the project's files, which is a
confusing five minutes if you don't expect it. A fresh worktree also needs
`./configure` before `make` (see Build).

Two caveats:

- Claude Code's own `EnterWorktree` tool creates worktrees under
  `.claude/worktrees/` instead, and that path is not configurable without
  `WorktreeCreate` hooks. Expect to see both locations; it's not a mistake.
- The git stash stack is **shared across all worktrees**. Never use bare
  `git stash` / `git stash pop` — you can pop someone else's work. Use a WIP
  commit, or `git stash push -m "<unique-tag>"` and `git stash apply <sha>`.

Run `git worktree list` before creating one, and `git worktree prune` if you
see an entry marked `prunable`.

---

## Repo hygiene — why `git status` and `git diff` look insane

- **`_install/` is `make install` output and is no longer tracked.** It was
  committed by accident in `610a1c933` — 228 files, ~43 MB, about 97% of
  this fork's diff against upstream — and has since been untracked and
  gitignored. Depending on how the tree was configured, `ocamlc -config` may
  report `_install/lib/ocaml` as its `standard_library`; if so the directory
  must exist on disk (`make install` recreates it). Never check it back in.
  It remains in git *history*, so clone size still reflects it, and a raw
  diff against a pre-cleanup commit still shows all 228 files.
- `lambda/matching.cmt4e44c0.tmp` — 0-byte compiler temp file, committed by
  accident.
- **`runtime/caml/mlvalues.h`'s 507-line diff is a pure no-op reformat**
  (brace style + macro line rejoining). No token changed. Not project work.
- `parsing/parsetree.mli`'s 1-line diff *corrupts the license header*
  (`projet` → `project`) and breaks its column alignment. Not project work.
- `parsing/ast_helper.ml`'s +3 lines are trailing whitespace only.
- `parsing/dune`, root `dune`, `dune-project` diffs are ~99% `dune fmt`
  noise; only two real lines (adding `snapshot` and `vreplay` to module
  lists).
- `.tmp_files/` is the authors' gitignored scratch area.

Apart from `_install/`, none of the above has been cleaned up. Just don't
mistake it for signal.

---

## Further reading

- **`vreplay/sexp.mli`** — the wire schema and its prose spec. The single
  most important file to read before touching serialization.
- **`README_C_Contributions.md`** — genuinely excellent 450-line in-repo
  guide to writing C in this tree: the `CAMLparam`/`CAMLlocal`/`CAMLreturn`
  GC contract, primitive registration, tag tables, debugging with
  `-runtime-variant d` and `OCAMLRUNPARAM='s=4k'`. **Read it before touching
  `runtime/`.**
- **`TEST.README.md`** — verified end-to-end commands for building and
  running the flag by hand.
- **`README_opam_switch.md`** — the `jsip-vreplay` switch (this fork as an
  installed compiler, with Core built against it).
- **`testing/README.md`** — what the golden suite checks and covers.
- `HACKING.adoc` — upstream's build/dev guide.
- `README_vreplay.md` — **half stale.** Its "Where the dump goes" section is
  current and authoritative; everything above it describes a layout from
  before the code moved to `typing/` and gives an invocation that no longer
  works.
