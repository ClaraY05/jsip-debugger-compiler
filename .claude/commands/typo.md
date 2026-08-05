---
description: Run the upstream check-typo style checker on this project's changed files
allowed-tools: Bash(./tools/check-typo-since:*), Bash(./tools/check-typo:*), Bash(git diff:*), Bash(git status:*), Read, Edit
---

Run the OCaml tree's own style checker over what this branch changed, and fix what it
finds.

## 1. Run it

```sh
./tools/check-typo-since trunk
```

`trunk` is the fork point (`511483454`), so this checks only files the project touched —
it is instant. Running bare `./tools/check-typo` scans the whole 1M-line tree and will
bury you in upstream noise; don't.

## 2. What the rules are

From `CONTRIBUTING.md:119-122`: no trailing whitespace, no lines over 80 columns, no tab
characters, ASCII only, and a newline at end of file.

New `.ml` / `.mli` / `.c` files also need the standard OCaml license header — the
`missing-header` check. Copy the 14-line block verbatim from `typing/typecore.ml:1-14`
and adjust nothing but the author/date lines. `.md`, `README*`, and `*.adoc` are exempt
via `.gitattributes:63-67`.

## 3. Expect pre-existing failures

Project files historically failed checks — missing headers on
`typing/vreplay_instrumentation.{ml,mli}` and `vreplay/src/snapshot.c`, long lines and
trailing whitespace throughout `typing/vreplay_instrumentation.ml` — and are now
exempted via `.gitattributes`.

**Fix what the current change touched. Do not embark on a tree-wide cleanup** unless
asked — it produces an enormous diff that buries the actual work.

Some violations are in files the project only touched *by accident*
(`parsing/ast_helper.ml`, `runtime/caml/mlvalues.h`, `parsing/parsetree.mli`). Those are
reformat noise, not project work; report them but leave them alone unless the user wants
that cleanup done deliberately.

## 4. Report

List what failed, what you fixed, and what you deliberately left.
