# jsip-visual-debugger

The outer shell of the JSIP visual replay debugger. One command runs the
whole pipeline — compile a program with the forked, instrumenting
compiler, capture its replay dump, and step through the run in the
debugger TUI:

```sh
git submodule update --init --recursive   # once, after cloning
./canary.sh examples/map_demo.ml                # one map, built and trimmed
./canary.sh examples/calculator                 # multi-file: lexer → parser → eval
./canary.sh examples/order_book/order_book.exe  # a Core limit order book
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
./canary.sh ~/jsip-exchange/app/debug_scenario/bin/main.exe
```

Artifacts go to a private `--build-dir`, so an instrumented `_build` is
never left behind in the project's checkout.

### Sharing the replay on the web

```sh
./canary.sh --web examples/map_demo.ml
```

`--web` runs the same pipeline and opens the TUI as usual, but also
serves the browser interface behind a temporary public URL (a
cloudflared quick tunnel), so someone who is not at this machine can
open the visualizer while you drive the TUI. The `trycloudflare.com`
link is printed before the TUI takes the terminal and kept in
`_vreplay/<program>/web/url`; quitting the TUI (`q`) ends the share.
(The `share-on-web` skill in `.claude/skills/share-on-web/` walks the
same steps by hand, e.g. to serve an existing dump without rerunning
the program.) The one piece neither can set up for you is `cloudflared`
itself, which needs root to install:

```sh
# Debian/Ubuntu
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
  -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb

# macOS
brew install cloudflared
```

Other platforms: grab a binary from
<https://github.com/cloudflare/cloudflared/releases>.

The link lives only while the tunnel runs, and it extends the debugger's
local file read (the server's `/api/source`) to anyone holding it —
share for a live demo, then tear it down.

#### Doing it by hand

`--web` is these steps; run them yourself to share an **existing** dump
without rerunning the program. How it works: `app/web/server/serve.exe`
is self-contained — the js_of_ocaml-compiled client is embedded in the
binary — and serves the replay's inputs itself on localhost only
(`/api/dump`, `/api/source`, `/api/heat`); the browser fetches the dump
and replays it with the same readers the TUI uses. The tunnel is an
*outbound* connection to Cloudflare's edge, which proxies a random
`trycloudflare.com` subdomain back to your loopback port — no account,
no open inbound ports, and the URL dies with the process.

One-time, after installing cloudflared (the web app's libraries are not
in the TUI's dependency set):

```sh
opam install --switch 5.2.0+ox -y bonsai_web async_js cohttp-async \
  js_of_ocaml-ppx ppx_html
cd jsip-debugger-interface
opam exec --switch 5.2.0+ox -- dune build --root . app/web/server/serve.exe
```

Each share (flag values for a pipeline run are under
`_vreplay/<program>/`; a `VREPLAY_DUMP_ONLY=1 ./canary.sh ...` run
prints them exactly):

```sh
jsip-debugger-interface/_build/default/app/web/server/serve.exe \
  -dump-file _vreplay/map_demo/map_demo.dump \
  -source-root _vreplay/map_demo/build/_build/default \
  -perf-file _vreplay/map_demo/heat.sexp        # wait for its ready line

cloudflared tunnel --url http://127.0.0.1:8080 --config /dev/null \
  --no-autoupdate                               # in a second terminal
```

The shareable URL is in cloudflared's startup banner (on stderr).
Teardown is Ctrl-C on both processes. Gotchas: `--config /dev/null` is
required if you have ever configured a named tunnel; no URL within ~15
seconds usually means QUIC is blocked — retry with `--protocol http2`
rather than waiting out cloudflared's own slow fallback.

`CLAUDE.md` has how the pieces fit together, including why linking Core
needs a switch built by the fork's own compiler and how that is wired up.

---

This repo's own OCaml code (the `canary` package) is in the Jane Street
style: [`Core`](https://opam.ocaml.org/packages/core/) as the standard
library, `ppx_jane` for deriving, `dune` for builds, expect tests, and the
`janestreet` ocamlformat profile.

The generated `canary.opam` is produced by dune from `dune-project` — don't
edit it by hand; it regenerates on the next `dune build`.

## Build, test, format

```sh
dune build                      # compile
dune runtest                    # run tests
dune fmt --auto-promote         # format (.ocamlformat: janestreet profile)
```

## GitHub Actions

Two workflows ship with this template:

- **`.github/workflows/ci.yml`** — builds, tests, and checks formatting on
  every push to `main` and every PR. Self-contained via `ocaml/setup-ocaml`;
  needs no secrets.
- **`.github/workflows/claude.yml`** — runs the
  [Claude Code Action](https://github.com/anthropics/claude-code-action) when
  someone writes `@claude` in an issue or PR.

The Claude workflow needs an `ANTHROPIC_API_KEY` secret, added under
**Settings → Secrets and variables → Actions**, or set as an **organization
secret** so all repos inherit it. (You can instead use a
`CLAUDE_CODE_OAUTH_TOKEN` from `/install-github-app`.)

## Layout

```
canary.sh          the pipeline driver
examples/          sample inputs for it
perf_heat/         the heat profile's demangler, perf-report parser
                   and aggregator (src/ and test/)
bin/               perf_heat_interface.exe, the CLI over it
```

See `CLAUDE.md` for the full code conventions.

## Submodules
This project contains submodules of other repositories

To update the copies of the submodules run `git submodule update --remote --merge`

These updates must be committed to the repo.
