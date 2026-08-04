# jsip-visual-debugger

The outer shell of the JSIP visual replay debugger. One command runs the
whole pipeline — compile a program with the forked, instrumenting
compiler, capture its replay dump, and step through the run in the
debugger TUI:

```sh
git submodule update --init --recursive   # once, after cloning
./cool_name.sh examples/greet.ml          # single-file program
./cool_name.sh examples/calculator        # multi-file program (needs a main.ml)
./cool_name.sh examples/map_demo.ml                # one map, built and trimmed
./cool_name.sh examples/order_book/order_book.exe  # a Core limit order book
```

The first run also builds the forked compiler (~10 min) and assembles a
toolchain from it; later runs reuse both until the pinned commit changes.

Give it a loose `.ml` file and it is wrapped in a scratch dune project.
Give it something that is **already a dune target** — either the `.exe`,
as the order book above does, or an `.ml` with a `dune` beside it — and
the project it belongs to is built where it stands, keeping its own
libraries, ppx and dependencies. That is how a whole program comes in:

```sh
./cool_name.sh ~/jsip-exchange/app/debug_scenario/bin/main.exe
```

Artifacts go to a private `--build-dir`, so an instrumented `_build` is
never left behind in the project's checkout.

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

## Compute heat profiles

Alongside the replay dump, the pipeline perf-samples the **unchanged**
program — natively compiled with the `5.2.0+ox` opam switch's `ocamlopt`
and looped in-process so even a microsecond-scale program accumulates
enough samples — and distills the report into a per-function compute
profile, `_vreplay/<name>/heat.sexp`:

```
((version 1) (root_module Greet)
 (entries
  (((module_path (Greet)) (kind (Named shout)) (samples 8841))
   ((module_path (Greet)) (kind (Named generate_string)) (samples 3819)))))
```

That sexp is the data contract with the interface (mirrored by its
`Jsip_types.Heat_profile`), which colors each call-stack row by its
function's share of sampled compute. `perf_heat/` (a top-level peer of the two
submodules, since it too produces the interface's input data) holds the symbol
demangler, perf-report parser, and profile writer; `bin/perf_heat_interface.exe` is the CLI face of perf — the report → sexp step `cool_name.sh` pipes through. The stage is
optional: no `perf` or no native switch just means a heat-less replay.

Caveats worth knowing: flambda2 may inline small functions away (they
show as "no data", not "cheap"), a `C_CALL`'s work is attributed to the
runtime rather than the calling function, and shares are measured on the
looped build. `COMPILER_DIR`/`INTERFACE_DIR` env vars point the pipeline
at checkouts other than the pinned submodules; `JSIP_HEAT_SWITCH`
overrides the opam switch used for the native build.

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
