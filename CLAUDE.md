# CLAUDE.md — jsip-visual-debugger

## About this project

The outer shell of the JSIP visual replay debugger — a tool for
recording an OCaml program's execution and replaying it visually. The
system spans three repos; this one ties the other two together as git
submodules and holds the glue: `cool_name.sh` (the one-command pipeline
driver) and any outer-shell OCaml code in `lib/` and `bin/` (still the
sandbox `hello` template, in the Jane Street style: `Core`, `ppx_jane`,
dune, expect tests).

The pipeline, all driven by `./cool_name.sh path/to/program.ml`: the
**compiler** submodule (an `ocaml/ocaml` fork), behind a
`-visual-replay` flag, instruments calls involving tracked data
structures (stdlib `Map`/`Set`/`Queue`/`Hashtbl`) so the running
program logs one event per call — its location, arguments, the live
registry, and a walked snapshot of the structure's heap shape — as one
`(event ...)` sexp per line, with `{`/`}` markers tracking call depth.
The log goes to its own sink (`VREPLAY_FILE=<path>`, or `VREPLAY_SOCK`
for a live socket listener, default `./vreplay.dump`), never stdout,
so program output cannot corrupt it. The **interface** submodule is a
GDB-style bonsai_term TUI that replays a dump: step through the run
and watch the call stack, source position, and heap shapes evolve.

## Submodules

`git clone --recurse-submodules`, or after the fact
`git submodule update --init --recursive` (the compiler has its own
`flexdll` submodule, hence `--recursive`). Each submodule is pinned to
the work branch named in `.gitmodules` — compiler:
`fix/walker-correctness`, interface: `worktree-debugger-tui` — so to
pick up new submodule commits: `git submodule update --remote --merge`,
then commit the bumped pointers here. Those are the currently-active
branches; as they merge, re-pin to the trunks (`vreplay-main` for the
compiler, `main` for the interface). Submodules check out detached;
don't develop inside them from this repo — push branches in their own
repos, then bump the pointer.

### jsip-debugger-compiler

Fork of `ocaml/ocaml` trunk (5.6.0+dev0) at
<https://github.com/ClaraY05/jsip-debugger-compiler>, pinned to
`fix/walker-correctness` — the fork's `vreplay-main` integration
branch plus emit-sink and walker fixes (`c/snapshot` and
`c/vreplay-registry-dynarray` are earlier phases). What the fork adds:

- `Clflags.visual_replay` (the `-visual-replay` flag) gates everything.
- `typing/vreplay_instrumentation.ml{,i}` rewrites the typedtree,
  wrapping calls whose arguments or result involve a structure from
  the catalogue (currently stdlib `Map`, `Set`, `Queue`, `Hashtbl`).
- `vreplay/` — runtime library auto-linked under the flag
  (`bytecomp/bytelink.ml` inserts `vreplay.cma` after `stdlib.cma`;
  `driver/compmisc.ml` puts `+vreplay` on the load path). It assigns
  tracked values stable ids in a weak registry and walks their heap
  shape for each event's snapshot.
- `runtime/snapshot.c` — the `caml_wire_emit` primitive and the dump
  sink, chosen at first emit: `VREPLAY_SOCK=<path>` (Unix stream
  socket, falls through to the file sink if the connect fails),
  `VREPLAY_FILE=<path>`, else `./vreplay.dump`. Never stdout.
  Instrumented bytecode must run under the fork's own `ocamlrun`.
- `testing/` — golden-dump cases and `run_tests.sh`: compiles and runs
  each case, validates every dump line parses and depth balances, and
  diffs against `expected/` up to a consistent address bijection
  (`--promote` regenerates). The interface vendors these goldens
  verbatim as its fixtures.

Build facts (cool_name automates all of this): bytecode only — `make
world`, never `world.opt`; native has never built on these branches.
The team layout configures with `--prefix=$PWD/_install`, and
bytecode-only `make install` is expected to abort at
`tools/ocamldep.opt` — after everything that matters is already
installed. When editing the fork, beware the stale-relink hazard its
`.claude/commands/build.md` documents: verify `./ocamlc` is newer than
your changed `.cmo`s. Upstream's contribution rules apply inside it,
including `AI.md` (disclose AI-generated portions).

### jsip-debugger-interface

The frontend, at <https://github.com/wuad391/jsip-debugger-interface>,
pinned to `worktree-debugger-tui`: the GDB-style terminal interface
built on bonsai_term — its README has the pane-by-pane tour and key
bindings. Layout: `lib/types` (calls, locations, snapshots, the call
stack), `lib/parsing` (dump reader and source loader), `lib/replay`
(the per-step replay model), `lib/tui` (panes, theme, app), and
`app/bin/main.exe`, run as
`main.exe -dump-file FILE [-source-root DIR]`. `testing/` vendors the
compiler's golden dumps verbatim, and the expect tests run on them.
Builds and tests clean on the OxCaml switch with plain `dune build` /
`dune runtest`. It has its own `CLAUDE.md` (same conventions as this
file) and repo-scoped skills (`bonsai-web`, `frontend-design`,
`ocaml-ppx`, `code-review`); follow those for any work under
`jsip-debugger-interface/`.

### The dune workspace and the submodules

The root `dune` file marks both submodules `data_only_dirs`: each is
its own project with its own toolchain story, so root `dune build` /
`runtest` / `fmt` cover only this repo's code, and CI checks out
neither submodule. To run dune on the nested interface checkout, force
its root: `cd jsip-debugger-interface && dune build --root .` (plain
`dune build` walks up to this repo's workspace, which ignores it).

## The cool_name pipeline

`./cool_name.sh path/to/program.ml` runs the whole pipeline on one
stdlib-only, single-file program; try
`./cool_name.sh examples/map_demo.ml`. Stages, with artifacts under
`_vreplay/<program-name>/` (gitignored):

1. Builds the forked compiler whenever the pinned submodule commit
   changes (stamped in `_install/.built-rev`): configure to
   `_install`, bytecode `make world`, one of the fork's golden-dump
   cases as validation, the tolerated partial install, hand-finished
   `ocamlc`/`ocamldep` symlinks. ~10 min from scratch; log at
   `_vreplay/compiler-build.log`.
2. Generates a scratch dune project (`(modes byte)`, `-visual-replay`;
   the module keeps the program's name when it is a valid module name)
   and builds it with the fork as the toolchain: shim scripts put the
   fork's `ocamlc`/`ocamldep` on PATH, each run through the fork's
   `ocamlrun`, and `-I <compiler>/vreplay` resolves `vreplay.cma` from
   where the fork's Makefile builds it.
3. Runs the bytecode under the fork's `ocamlrun` with
   `VREPLAY_FILE=<name>.dump`: events go to the dump, the program's
   own output stays on the terminal. A run that fires no events
   (nothing tracked) is an error, not an empty replay.
4. Builds the interface and execs the TUI on the dump, with
   `-source-root` pointed at the scratch project so the source pane
   resolves. `q` quits, back to your shell.

## Build, test, format

This project uses the external opam OCaml toolchain. Standard `dune`:

```sh
dune build                 # compile
dune runtest               # run all tests
dune fmt --auto-promote    # format (uses .ocamlformat: janestreet profile, margin 77)
dune build @doc            # generate odoc HTML
dune exec bin/main.exe -- Ada   # run the example binary
```

Never modify anything under `_build/` — it's regenerated by dune.

Root dune commands cover only this repo's code — the submodules are
excluded from the workspace (see the dune workspace note above).

Toolchain skew, pre-existing on a clean checkout of `main`: the local
opam switch is a Jane Street preview (`5.2.0+ox`, `dune 3.22+ox`,
preview `ppx_expect`), while CI installs standard opam releases.
Currently `dune runtest` crashes locally in the expect-test runtime
(`Sys_error ".../test_hello.ml"`), and CI's build step fails on
`lib/hello/test/test_hello.ml` because the standard
`expect_test_helpers_core` wants `require_does_raise [%here]` — so
`main` CI is red. Don't mistake either for a regression you caused.

## Code conventions

Match the existing style; don't introduce alternatives without a reason. When creating new files, instead of keeping them under the same directory, organize them into sub directories with a respective /src and /test subdirectory.

### Documentation

- Every lib needs docs
- Every module needs a comment
- All mli needs `(** doc *)`
- No useless comments (e.g., "adds numbers")
- Show examples
- Say how it fits with other modules
- Doc comments immediately after: `field : type (** doc *)`
- Use `[code]` and `{[blocks]}` in docs
- Use `{!Module.foo}` for links in docs
- `(*_ *)`: ignored by doc tools

### Naming

- Short scope = short name
- Bools: `is_foo` not `check_foo`
- Can raise? End with `_exn`
- Grabs/frees stuff? Start with `with_`
- American English only
- `snake_case` not `camelCase`
- `_`: unused only
- `unsafe`: can segfault. Name it `unchecked` otherwise
- No negative bools (e.g., `dont_foo`)
- Name constants
- Type params: `'a 'b` unless special (`'ok 'err`, `'k 'v` for maps)

### Printing

- `[%string "x is %{x}"]` not `sprintf`
- Always use `sprintf !` for `ppx_custom_printf`
- Always derive `sexp_of`
- `[%message]` > `[%sexp]` for humans

### Testing

- Make readable; use expect tests; tests in a separate dir
- Test-only stuff in `For_testing`
- Test files are named `test_<module>.ml` and live in `lib/<x>/test/`.
- Tests are `let%expect_test "<name>" = ...` with `[%expect {| ... |}]`
  blocks. `let%test` is fine for property-style boolean checks;
  `let%test_unit` for tests without expected output.
- When updating expect output, run `dune runtest --auto-promote` — but
  **read the diff first**. A surprising diff is a real signal.

### Interfaces

- Most modules have `type t`
- Most types are called `t`
- Args: `?optional`, `t`, positional, `~labeled`; label unclear args
- No new infix ops
- No `helpers.ml`
- Avoid functors (use first-class modules)

### Managing namespaces

- Only open if made for opening (`Let_syntax`, `O`, `Composition_infix`)
- `_intf.ml` for shared types
- Make a top-level lib module (see `lib/hello/src/sandbox_hello.ml`)
- Small lib = one module
- Don't alias modules (if must: keep name same)

### Style preferences

- Short match first
- Match > if
- No `else ()`
- No `let...and...` (except monads)
- Type annotations > module paths
- Normal variants > poly variants
- `f();` not `let () = f()`
- Pass `[%here]` when function takes `Source_code_position.t`
- `^/` for paths
- `Time_ns` > `Time_float`

### Avoiding error-prone idioms

- No `| _ ->` when matching on variants
- Write types on ignored stuff (except record fields, labeled args, variant args)
- Use returned values
- No polymorphic compare

### Error handling

- Explicit error types; no `exception` in interfaces
- Raise: `_exn` only; make `ok_exn` visible
- Check human input (`sexp`/`json`); machine formats (`bin_io`) need no validation
- Add context
- For library-internal precondition violations: `raise_s [%message "..." (x : T.t)]`.
- For fallible operations exposed at module boundaries: return `'a Or_error.t`,
  build errors with `Or_error.error_s [%message ...]`.
- Prefer `Or_error.t` over `Result.t` directly.

### Opens

```ocaml
open! Core              (* always, for every src/test/bin .ml *)
```

The `!` suppresses unused-open warnings. Don't replace `Core` with
`Stdlib`; don't import individual functions from `Core`.

### Dune files

Libraries follow a uniform pattern:

```
(library
 (name sandbox_<x>)
 (public_name sandbox.<x>)
 (libraries <deps>)
 (preprocess (pps ppx_jane)))
```

Tests:

```
(library
 (name sandbox_<x>_test)
 (libraries sandbox_<x> expect_test_helpers_core core)
 (inline_tests)
 (preprocess (pps ppx_jane)))
```

dune discovers libraries automatically as long as they have a `dune` file.

## Project layout

```
jsip-debugger-compiler/    submodule: OCaml compiler fork, pinned to
                           c/vreplay-registry-dynarray
jsip-debugger-interface/   submodule: frontend, pinned to parsing (has
                           its own CLAUDE.md and skills)
cool_name.sh               the pipeline driver (see above)
examples/map_demo.ml       sample input for it
_vreplay/                  its gitignored working area
dune                       excludes the submodules from the workspace
lib/
  hello/
    src/     example library (Sandbox_hello.Hello)
    test/    expect tests for it
bin/
  main.ml    example executable
```
