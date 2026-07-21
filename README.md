# OCaml project template

A blank OCaml project in the Jane Street style: [`Core`](https://opam.ocaml.org/packages/core/)
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
