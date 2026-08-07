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
  scales with the capture, so record a bounded window and trim it, as
  *Capturing a long-running program* shows below.

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

- The URL is a cloudflared quick tunnel to a web server on loopback.
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

The shareable URL is in cloudflared's startup banner (on stderr);
teardown is Ctrl-C on both processes. Gotchas:

- `--config /dev/null` is required if you have ever configured a named
  tunnel.
- No URL within ~15 seconds usually means QUIC is blocked — retry with
  `--protocol http2` rather than waiting out cloudflared's own slow
  fallback.

### Capturing a long-running program

A server-style program runs until interrupted, so capture first and
replay after — `VREPLAY_DUMP_ONLY` stops the pipeline once the dump is
on disk. The order book stands in for the long-running target below;
substitute your own, as above:

```sh
VREPLAY_DUMP_ONLY=1 ./canary.sh examples/order_book/order_book.exe
# a program that does not end on its own: let it run 15–30 seconds,
# then Ctrl-C

sed -i '${/^[{}]*$/d}' _vreplay/order_book/order_book.dump  # drop the torn final marker line
```

The heat profile comes with it:

- the perf job runs for any program, project mode included, and
  `VREPLAY_DUMP_ONLY` waits for it before exiting;
- only a program you interrupt needs doing by hand, since the job
  records a run that ends on its own:

```sh
dune build examples/order_book/order_book.exe

perf record -F max -o /tmp/order_book.perf.data -- \
  _build/default/examples/order_book/order_book.exe
  # same 15–30 seconds, then Ctrl-C

perf report -i /tmp/order_book.perf.data --stdio --dsos order_book.exe \
  --percent-limit 0 -F sample,sym |
  dune exec bin/perf_heat_interface.exe -- Order_book _vreplay/order_book/heat.sexp
```

About that recording:

- Record without `-g`: the distiller reads the flat report, and a
  callchain one is mostly lines it cannot parse.
- `Order_book` is the profiled program's entry module — it breaks ties
  between a function of yours and a same-named library one.
- The distiller exits 3 if fewer than 2000 samples landed in OCaml
  code — record for longer.

Now replay, with `-perf-file` for the heat and the interface built by
hand (stopping at the dump also stops before the step that builds it):

```sh
(cd jsip-debugger-interface && dune build --root . app/bin/main.exe)

jsip-debugger-interface/_build/default/app/bin/main.exe \
  -dump-file _vreplay/order_book/order_book.dump \
  -source-root . \
  -perf-file _vreplay/order_book/heat.sexp
```

Worth knowing for this workflow:

- `-source-root` is the project root in project mode — here this repo
  itself — and the scratch build context for a loose `.ml` or
  directory; the `VREPLAY_DUMP_ONLY` run prints the exact flags for
  its capture.
- The heat colors each callee's name in the call stack by its share of
  sampled compute. It matches by function name and module, so it is a
  different run's statistics laid over this run's calls, and a callee
  the optimizer inlined away — `Hashtbl.incr`,
  `Order_queue.enqueue_back_exn` — has no symbol to match and stays
  uncolored.
- Interrupting mid-event tears the dump's last line, which the reader
  rejects — the `sed` above deletes it.
- Load time scales with the capture: a two-minute run is ~18k events
  and takes about a minute to open; 20–30 seconds opens in seconds. On
  a dump that size the navigation aids earn their keep: `/` filters
  structures, `z` is accordion mode, `h` collapses at the cursor.
- A foreign checkout must build against the toolchain's library
  versions — expect a small, mechanical compatibility pass if it pins
  newer ones.

Alongside all that it runs a **perf job**, in the background, for every
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

This repo's own OCaml code (the `canary` package) is in the Jane Street
style:

- [`Core`](https://opam.ocaml.org/packages/core/) as the standard
  library
- `ppx_jane` for deriving
- `dune` for builds
- expect tests
- the `janestreet` ocamlformat profile

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
