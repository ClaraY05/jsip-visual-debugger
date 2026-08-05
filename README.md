# jsip-visual-debugger

The outer shell of the JSIP visual replay debugger. One command runs the
whole pipeline — compile a program with the forked, instrumenting
compiler, capture its replay dump, and step through the run in the
debugger TUI:

```sh
git submodule update --init --recursive   # once, after cloning
./cool_name.sh examples/map_demo.ml                # one map, built and trimmed
./cool_name.sh examples/calculator                 # multi-file: lexer → parser → eval
./cool_name.sh examples/order_book/order_book.exe  # a Core limit order book
```

The first run also builds the forked compiler (~4 min) and assembles a
toolchain from it; later runs reuse both until the pinned commit changes.

Give it a loose `.ml` file and it is wrapped in a scratch dune project; a
**directory** is the same but multi-file, entering at `main.ml` with the
rest as ordinary dependency modules. Give it something that is **already
a dune target** — either the `.exe`, as the order book above does, or an
`.ml` with a `dune` beside it — and the project it belongs to is built
where it stands, keeping its own libraries, ppx and dependencies. That is
how a whole program comes in:

```sh
./cool_name.sh ~/jsip-exchange/app/debug_scenario/bin/main.exe
```

Artifacts go to a private `--build-dir`, so an instrumented `_build` is
never left behind in the project's checkout.

### Capturing a long-running program

An exchange scenario runs until interrupted, so capture first and replay
after — `VREPLAY_DUMP_ONLY` stops the pipeline once the dump is on disk:

```sh
VREPLAY_DUMP_ONLY=1 ./cool_name.sh \
  ../test/jsip-exchange/app/scenario_runner/bin/main.exe -scenario book-filler -seed 0
# let the market run 15–30 seconds, then Ctrl-C

sed -i '${/^[{}]*$/d}' _vreplay/main/main.dump    # drop the torn final marker line
```

Then the heat profile, by hand — `VREPLAY_DUMP_ONLY` exits before the
pipeline's perf stage, and that stage would be no use here anyway: it
loops the program in-process to accumulate samples, and a program that
runs until you interrupt it never comes back from the first iteration.
Profile the real thing instead — the same scenario, natively built and
uninstrumented, recorded for about as long as the capture ran:

```sh
(cd ../test/jsip-exchange && dune build app/scenario_runner/bin/main.exe)

perf record -F max -o /tmp/scenario.perf.data -- \
  ../test/jsip-exchange/_build/default/app/scenario_runner/bin/main.exe \
  -scenario book-filler -seed 0     # same 15–30 seconds, then Ctrl-C

perf report -i /tmp/scenario.perf.data --stdio --dsos main.exe \
  --percent-limit 0 -F sample,sym |
  dune exec bin/perf_heat_interface.exe -- Main _vreplay/main/heat.sexp
```

Record without `-g`: the distiller reads the flat report, and a
callchain one is mostly lines it cannot parse. `Main` is the profiled
program's entry module, which breaks ties between a function of yours
and a same-named library one. It exits 3 if fewer than 2000 samples
landed in OCaml code — record for longer.

Now replay, with `-perf-file` for the heat and the interface built by
hand (stopping at the dump also stops before the step that builds it):

```sh
(cd jsip-debugger-interface && dune build --root . app/bin/main.exe)

jsip-debugger-interface/_build/default/app/bin/main.exe \
  -dump-file _vreplay/main/main.dump \
  -source-root _vreplay/main/build/default \
  -perf-file _vreplay/main/heat.sexp
```

The heat colors each callee's name in the call stack by its share of
sampled compute. It matches by function name and module, so it is a
different run's statistics laid over this run's calls, and a callee the
optimizer inlined away — `Hashtbl.incr`, `Order_queue.enqueue_back_exn`
— has no symbol to match and stays uncolored.

Interrupting mid-event tears the dump's last line, which the reader
rejects — the `sed` deletes it. Load time scales with the capture (a
two-minute run is ~18k events and takes about a minute to open; 20–30
seconds of market opens in seconds), and on a dump that size the
navigation aids earn their keep: `/` filters structures, `z` is
accordion mode, `h` collapses at the cursor. The exchange checkout must
build against the toolchain's library versions — see the
`vreplay-compat` branch in the exchange repo for the (small, mechanical)
compatibility pass.

For programs whose sources are ours — a loose file or a directory, not
someone else's dune project — it also captures a **perf heat profile**:
the unchanged program text, compiled natively and looped in-process,
sampled with `perf`, distilled into `heat.sexp` for the interface to
colour its call stack with, and passed on `-perf-file` when it launches
the TUI. Optional throughout; it says so and carries on when `perf`, the
native switch or the interface's `-perf-file` flag is missing — and it
is skipped entirely under `VREPLAY_DUMP_ONLY`, which stops the run
before that stage.

What gets recorded: calls involving a container the compiler knows —
the stdlib's `Map`/`Set`/`Queue`/`Hashtbl`/`Stack`/`Dynarray` and
Core's `Map`/`Set`/`Hashtbl`/`Hash_set`/`Hash_queue`/`Queue`/`Stack`/
`Deque`/`Fdeque`/`Doubly_linked` — and every binding of a value whose
type the program declares itself, so a record of your own is a
first-class thing on the heap pane, not just some container's contents.
Core's containers are recorded under their own names (`core.map`,
`core.hash_queue`, …) rather than folded into the stdlib's: a Core map
is a record over a tagged tree where the stdlib's map *is* the tree.

One asymmetry to know: an event rooted at a **mutation** needs a named
identifier, so `Hashtbl.set tbl ~key ~data` is recorded and
`Hashtbl.set t.field ...` is not, while a tracked **result** fires
through record fields either way.

`CLAUDE.md` has how the pieces fit together, including why linking Core
needs a switch built by the fork's own compiler and how that is wired up.

---

Based on an OCaml project template in the Jane Street style: [`Core`](https://opam.ocaml.org/packages/core/)
as the standard library, `ppx_jane` for deriving, `dune` for builds, expect
tests, and the `janestreet` ocamlformat profile. Wired up with GitHub Actions
and the Claude GitHub Action.

Click **"Use this template"** to start a new project from it.

## First use: rename the package

Everything is named `sandbox` as a placeholder. To rename it to `<your_name>`:

1. `dune-project` — the `(name sandbox)` in the `(package ...)` stanza.
2. `lib/hello/src/dune` and `lib/hello/test/dune` — `sandbox_hello`,
   `sandbox.hello`, `sandbox_hello_test`.
3. `lib/hello/src/sandbox_hello.ml` / `.mli` — rename both files, and update
   the `open Sandbox_hello` references in `bin/main.ml` and
   `lib/hello/test/test_hello.ml`.

The generated `sandbox.opam` is produced by dune from `dune-project` — don't
edit it by hand; it regenerates on the next `dune build`.

## Build, test, format

```sh
dune build                      # compile
dune runtest                    # run tests
dune fmt --auto-promote         # format (.ocamlformat: janestreet profile)
dune exec bin/main.exe -- Ada   # run the example binary
```

## GitHub Actions

Two workflows ship with this template:

- **`.github/workflows/ci.yml`** — builds, tests, and checks formatting on
  every push to `main` and every PR. Self-contained via `ocaml/setup-ocaml`;
  needs no secrets.
- **`.github/workflows/claude.yml`** — runs the
  [Claude Code Action](https://github.com/anthropics/claude-code-action) when
  someone writes `@claude` in an issue or PR.

The Claude workflow needs an `ANTHROPIC_API_KEY` secret, which is **not**
copied when you create a repo from this template. In each new repo add it under
**Settings → Secrets and variables → Actions**, or set it as an **organization
secret** so all repos inherit it. (You can instead use a
`CLAUDE_CODE_OAUTH_TOKEN` from `/install-github-app`.)

## Layout

```
lib/hello/src/    example library (Sandbox_hello.Hello)
lib/hello/test/   expect tests
bin/main.ml       example executable
```

See `CLAUDE.md` for the full code conventions.

## Submodules
This project contains submodules of other repositories

To update the copies of the submodules run `git submodule update --remote --merge`

These updates must be committed to the repo.
