# jsip-visual-debugger

The outer shell of the JSIP visual replay debugger. One command runs the
whole pipeline — compile a program with the forked, instrumenting
compiler, capture its replay dump, and step through the run in the
debugger TUI.

### Known limits

The debugger is at its best on small, direct-style programs that run to
completion. It still works, but is not at its most functional, for
programs that:

- use **Async**;
- use **bin_io**;
- are **long running** — the dump grows with every event and load time
  scales with the capture (`VREPLAY_DUMP_ONLY=1` captures a bounded
  window without opening the TUI).

### Running it

```sh
git submodule update --init --recursive   # once, after cloning
./canary.sh examples/map_demo.ml                # one map, built and trimmed
./canary.sh examples/calculator                 # multi-file: lexer → parser → eval
./canary.sh examples/order_book/order_book.exe  # a Core limit order book
```

The first run also builds the forked compiler (~4 min) and assembles a
toolchain from it; later runs reuse both until the pinned commit changes.

What you hand it decides how the program is built:

| You give it | How it is built |
| --- | --- |
| a loose `.ml` file | wrapped in a scratch dune project |
| a **directory** | same, but multi-file: enters at `main.ml`, the rest are ordinary dependency modules |
| something **already a dune target** — the `.exe` (as the order book above), or an `.ml` with a `dune` beside it | the project it belongs to is built where it stands, keeping its own libraries, ppx and dependencies |

Nothing is special about `examples/`: any of the paths above can be
replaced by an individual `.ml` of your own, a directory of modules, or
a path into any checkout with a dune project — that is how a whole
program comes in. Artifacts go to a private `--build-dir`, so an
instrumented `_build` is never left behind in the project's checkout.

### Running it with `--web`

```sh
./canary.sh --web examples/map_demo.ml
```

`--web` runs the same pipeline but, instead of opening the TUI, serves
the browser interface behind a temporary public URL, so someone who is
not at this machine can open the visualizer:

- The URL is a cloudflared quick tunnel to a web server on loopback
  (`VREPLAY_WEB_PORT`, default 8080).
- The web server builds on the perf job's switch (`JSIP_HEAT_SWITCH`,
  default `5.2.0+ox`) — its libraries are not in the TUI's dependency
  set, which is why it has its own one-time install below.
- The `trycloudflare.com` link is printed and kept in
  `_vreplay/<program>/web/url`.
- The script stays in the foreground; Ctrl-C ends the share.
- The `share-on-web` skill in `.claude/skills/share-on-web/` walks the
  same steps by hand, e.g. to serve an existing dump without rerunning
  the program.

The one piece neither can set up for you is `cloudflared` itself, which
needs root to install:

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

Two sharing caveats:

- the link lives only while the tunnel runs;
- it extends the debugger's local file read (the server's
  `/api/source`) to anyone holding it — share for a live demo, then
  tear it down.

#### Doing it by hand

`--web` is these steps; run them yourself to share an **existing** dump
without rerunning the program. How it works:

- `app/web/server/serve.exe` is self-contained — the
  js_of_ocaml-compiled client is embedded in the binary — and serves
  the replay's inputs itself on localhost only (`/api/dump`,
  `/api/source`, `/api/heat`).
- The browser fetches the dump and replays it with the same readers
  the TUI uses.
- The tunnel is an *outbound* connection to Cloudflare's edge, which
  proxies a random `trycloudflare.com` subdomain back to your loopback
  port — no account, no open inbound ports, and the URL dies with the
  process.

One-time, after installing cloudflared (the web app's libraries are not
in the TUI's dependency set; `5.2.0+ox` below is the default — use your
`JSIP_HEAT_SWITCH` if you run the pipeline with a different one):

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

The example is a standalone-mode run; the flags in general:

- `-dump-file` — `_vreplay/<program>/<program>.dump`.
- `-source-root` — the scratch build context
  `_vreplay/<program>/build/_build/default` in standalone mode (as
  above), but the **project's own root** in project mode.
- `-perf-file` — `_vreplay/<program>/heat.sexp`, only when the perf
  job wrote one; omit it otherwise.
- `-port` — default 8080. If that port is taken, pass another and
  point cloudflared's `--url` at the same one.

The shareable URL is in cloudflared's startup banner (on stderr);
teardown is Ctrl-C on both processes. Gotchas:

- `--config /dev/null` is required if you have ever configured a named
  tunnel.
- No URL within ~15 seconds usually means QUIC is blocked — retry with
  `--protocol http2` rather than waiting out cloudflared's own slow
  fallback.

The pipeline also runs a **perf job**, in the background, for every
kind of program including a project built in place:

- The job builds a second copy of the program with no instrumentation
  in it, natively, on the ordinary switch, records that under `perf`,
  and distils the report into `heat.sexp` — the per-function profile
  the interface colours its call stack with, passed on `-perf-file`
  when the TUI opens.
- The main line waits for it after the capture and prints what it
  managed.
- Optional throughout: it says so and carries on when `perf`, the
  native switch or the interface's `-perf-file` flag is missing, and a
  program with too little of its own code to sample simply gets no
  profile.

What gets recorded:

- **Calls involving a container the compiler knows** — the stdlib's
  `Map`/`Set`/`Queue`/`Hashtbl`/`Stack`/`Dynarray` and Core's
  `Map`/`Set`/`Hashtbl`/`Hash_set`/`Hash_queue`/`Queue`/`Stack`/
  `Deque`/`Fdeque`/`Doubly_linked`.
- **Every binding of a value whose type the program declares itself**,
  so a record of your own is a first-class thing on the heap pane, not
  just some container's contents.
- Core's containers are recorded under their own names (`core.map`,
  `core.hash_queue`, …) rather than folded into the stdlib's: a Core
  map is a record over a tagged tree where the stdlib's map *is* the
  tree.
- One asymmetry to know: an event rooted at a **mutation** needs a
  named identifier — `Hashtbl.set tbl ~key ~data` is recorded,
  `Hashtbl.set t.field ...` is not — while a tracked **result** fires
  through record fields either way.

`CLAUDE.md` has how the pieces fit together, including why linking Core
needs a switch built by the fork's own compiler and how that is wired up.

---

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

The Claude workflow needs one secret, either:

- an `ANTHROPIC_API_KEY`, added under **Settings → Secrets and
  variables → Actions** or set as an **organization secret** so all
  repos inherit it; or
- a `CLAUDE_CODE_OAUTH_TOKEN` from `/install-github-app`.

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
