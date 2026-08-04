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
`-visual-replay` flag, instruments calls involving a catalogued data
structure — stdlib `Map`/`Set`/`Queue`/`Hashtbl`/`Stack`/`Dynarray`,
Base and Core's containers, and values of types the program itself
declared — so the running program logs one event per call: its
location, arguments, the live registry, and a walked snapshot of the
structure's heap shape, as one
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
the work branch named in `.gitmodules` — compiler: `vreplay-main`
(its integration branch), interface: `worktree-debugger-tui` — so to
pick up new submodule commits: `git submodule update --remote --merge`,
then commit the bumped pointers here. Re-pin the interface to `main`
once the TUI branch merges. Submodules check out detached; don't
develop inside them from this repo — push branches in their own repos,
then bump the pointer.

### jsip-debugger-compiler

Fork of `ocaml/ocaml` trunk (5.6.0+dev0) at
<https://github.com/ClaraY05/jsip-debugger-compiler>, pinned to
`vreplay-main` — the fork's integration branch, with the
`fix/walker-correctness` emit-sink and walker fixes merged in
(`c/snapshot` and `c/vreplay-registry-dynarray` are earlier phases).
What the fork adds:

- `Clflags.visual_replay` (the `-visual-replay` flag) gates everything.
- `typing/vreplay_instrumentation.ml{,i}` rewrites the typedtree,
  wrapping calls whose arguments or result involve a structure from
  `vreplay/data_structure.ml`'s catalogue — that file is the authority
  on what is tracked and on each one's heap layout, and the interface
  mirrors its constructor names.
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

`./cool_name.sh path/to/program.ml [args...]` runs the whole pipeline,
or `path/to/target.exe` to name a dune target instead of a source file.
Two examples ship with it: `map_demo.ml` (one map, built and trimmed)
and `order_book/` (a Core limit order book with price-time priority — a
`Map` of price levels over `Hash_queue`s, a `Hashtbl` id index, two
`Hash_set`s and an `Fdeque` tape, all holding the same order records, so
the heap pane draws each order once and points at it from every
container it is in; 189 events, six `ds_type`s). Artifacts go under
`_vreplay/<program-name>/`, the toolchain under `_vreplay/.toolchain/`,
both gitignored.

1. Builds the forked compiler whenever the pinned submodule commit
   changes (stamped in `_install/.built-rev`): configure to
   `_install`, bytecode `make world`, one of the fork's golden-dump
   cases as validation, the tolerated partial install, hand-finished
   `ocamlc`/`ocamldep` symlinks. 3 min 35 s from scratch on 4 cores
   (measured 2026-08-03, all 464 `.cmo`s built, nothing reused); log at
   `_vreplay/compiler-build.log`.
2. Assembles a toolchain — see below — pairing the fork's compiler with
   an opam switch's libraries.
3. Compiles with `-visual-replay`, in one of two modes:
   - **project**, when there is a `dune` beside the file: the project it
     belongs to is built where it stands, so it keeps its own libraries,
     ppx and dependencies. Artifacts go to a private `--build-dir` so an
     instrumented `_build` is never left in the checkout, and the
     executable target is read out of the `dune` stanza (override with
     `VREPLAY_TARGET`).
   - **standalone**, for a loose `.ml`: a scratch dune project with
     `(modes byte)`, `-visual-replay`, and `(libraries ...)` plus
     `ppx_jane` inferred from the file's `open`s. The module keeps the
     program's name when that is a valid module name.
   The build directory survives between runs so dune stays incremental;
   a change of compiler or switch invalidates it.
4. Runs the resulting `-custom` executable with
   `VREPLAY_FILE=<name>.dump`: events go to the dump, the program's
   own output stays on the terminal. A run that fires no events
   (nothing tracked) is an error, not an empty replay. `VREPLAY_DUMP_ONLY`
   stops here.
5. Builds the interface and execs the TUI on the dump, with
   `-source-root` at the project root (project mode) or the scratch
   build context (standalone). `q` quits, back to your shell.

### The toolchain, and why it takes assembling

A compiler reads only `.cmi` files written by its own exact version —
there is no forward compatibility in either direction, which is what
opam switches exist to manage. The fork stamps `Caml1999I037`; the
OxCaml `5.2.0+ox` switch this repo is otherwise built with stamps
`Caml1999I578`. So linking Core into an instrumented program needs a
switch whose Core was compiled *by the fork's version*. That is
`VREPLAY_SWITCH`, default `jsip-vreplay`.

That switch's own `ocamlc` is older than the pinned submodule and its
`libcamlrun.a` is the matching older C walker, so step 2 takes its
libraries and splices the fork's compiler and runtime over the top:

- `OCAMLLIB` — a private copy of the switch's `lib/ocaml` carrying the
  fork's `libcamlrun*` and `vreplay/*`. These two move together: the
  fork's OCaml-side vreplay over the switch's older walker links clean
  and then **segfaults on the first event**. `-visual-replay` puts
  `+vreplay` on the load path itself, and `+` resolves against
  `OCAMLLIB`, which is what lets a foreign project build with no added
  flags — we cannot edit someone else's `dune`.
- `PATH` — shims first (`ocamlc` is the fork's with `-visual-replay`
  forced on, everything else symlinked from the switch), then a mirror
  of the inherited PATH **with every OCaml binary left out**. That
  mirror is load-bearing: dune decides native is available by finding an
  `ocamlopt` on PATH and does *not* believe `ocamlc -config`'s
  `native_compiler`, so any stray `ocamlopt` — there is a system OCaml
  4.14 in `/usr/bin` — gets picked up and handed `-visual-replay`, which
  it does not understand. Dropping `/usr/bin` wholesale is not an option
  because `gcc` and `ld` live there.

The remaining alternative, if this ever gets tiresome: port the vreplay
patches onto OxCaml itself, so the existing switch just works. Nothing
to shim, but it is a fork of a fork to maintain.

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
jsip-debugger-compiler/    submodule: OCaml compiler fork, tracking
                           vreplay-main
jsip-debugger-interface/   submodule: frontend, tracking
                           worktree-debugger-tui (has its own CLAUDE.md
                           and skills)
cool_name.sh               the pipeline driver (see above)
examples/                  sample inputs for it: map_demo.ml,
                           order_book/ (Core)
_vreplay/                  its gitignored working area, including the
                           assembled .toolchain/
dune                       excludes the submodules from the workspace
lib/
  hello/
    src/     example library (Sandbox_hello.Hello)
    test/    expect tests for it
bin/
  main.ml    example executable
```
