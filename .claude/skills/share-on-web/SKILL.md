---
name: share-on-web
description: Build the Bonsai web interface and expose it on a temporary public URL using a cloudflared quick tunnel, so someone else can open the visualizer in a browser. Use this whenever the user wants to share, demo, present, or show the debugger UI to another person — including phrasings like "share this on web", "get me a link", "can Robyn see this", "put this online", "expose this", "make a public URL", "let me demo this", or any request that implies a person who is not at this machine needs to view the running interface. Also use it when the user asks how to share the visualizer, even if they have not asked to start it yet.
---

# Share on web

Serve the web interface from this machine and put a temporary public URL in
front of it with a cloudflared quick tunnel.

The URL is alive only while the tunnel process runs. That is intended — sharing
here is for live presenting, not for publishing. Say so when you hand over the
link, so nobody is surprised when it stops working.

How the pieces fit: the interface submodule's `app/web/server/serve.exe` is
self-contained — the js_of_ocaml-compiled client and its page are embedded in
the binary — and serves the replay's inputs itself (`/api/dump`,
`/api/source`, `/api/heat`). It binds to localhost only, so the tunnel is the
only thing that makes it reachable. There is no separate static file server to
run, and nothing to serve with `python3 -m http.server`.

## Before starting

Two prerequisites, checked in this order:

1. `cloudflared` on PATH:

   ```bash
   command -v cloudflared
   ```

   If it is missing, stop and tell the user how to install it for their
   platform (`brew install cloudflared`, or the `.deb`/binary from
   Cloudflare's releases). Do not silently fall back to some other tunnel
   provider — the user asked for a share link and should know which service
   is about to carry their code.

2. The web app's libraries on the OxCaml switch (the TUI's dependencies do
   not cover them):

   ```bash
   opam exec --switch 5.2.0+ox -- ocamlfind list | grep -E 'bonsai_web|cohttp-async|async_js'
   ```

   If any are missing:

   ```bash
   opam install --switch 5.2.0+ox -y bonsai_web async_js cohttp-async js_of_ocaml-ppx
   ```

   This is a large dependency tree; expect the install to take a while on
   first run.

## Step 1 — Build the server

The interface is excluded from this repo's dune workspace, so force its root,
and build on the OxCaml switch:

```bash
cd jsip-debugger-interface
opam exec --switch 5.2.0+ox -- dune build --root . app/web/server/serve.exe
```

If the build fails, stop here and report the errors. A tunnel to a broken or
stale bundle wastes the user's time and is confusing to debug from the browser
side.

## Step 2 — Have a dump to replay

The server takes the same inputs as the TUI. A pipeline run has usually
already left them under `_vreplay/<program>/`:

- `-dump-file` — `_vreplay/<program>/<program>.dump`
- `-source-root` — the project root in project mode; the scratch build
  context `_vreplay/<program>/build/_build/default` in standalone mode
- `-perf-file` — `_vreplay/<program>/heat.sexp`, when the perf job wrote one

If there is no dump yet, capture one without opening the TUI:

```bash
VREPLAY_DUMP_ONLY=1 ./canary.sh examples/map_demo.ml
```

Its final lines print the exact `-dump-file`/`-source-root`/`-perf-file`
values for that run.

## Step 3 — Run the server

```bash
jsip-debugger-interface/_build/default/app/web/server/serve.exe \
  -dump-file <dump> -source-root <dir> [-perf-file <heat.sexp>] [-port 8080]
```

Run it in the background and wait for its ready line on stdout:

```
jsip web debugger → http://localhost:8080
```

It fails fast (before listening) if the dump is unreadable, so a missing
ready line means a bad `-dump-file`, not a slow start. It always binds
loopback; there is no flag to widen that, deliberately. If port 8080 is
taken, pass `-port` and use the same port in the next step.

## Step 4 — Start the tunnel

```bash
cloudflared tunnel --url http://127.0.0.1:8080 --config /dev/null --no-autoupdate
```

`--config /dev/null` matters: quick tunnels are not supported when a
`config.yaml` exists in the user's `.cloudflared` directory, and anyone who has
previously set up a named tunnel will have one.

cloudflared prints its banner to **stderr**, not stdout. Watch stderr for a line
matching:

```
https://[a-z0-9-]+\.trycloudflare\.com
```

Wait for that URL before reporting anything. If nothing appears within about 15
seconds, the QUIC handshake is probably being blocked — cloudflared retries with
exponential backoff up to 64 seconds before falling back on its own, which looks
like a hang. Kill it and retry with `--protocol http2` rather than waiting.

## Step 5 — Hand over the link

Report the URL plainly, and include what the user needs to know:

- the link works only while this process is running
- anyone with the link can use the interface — it is unguessable, not private
- **the link extends local file read to whoever holds it**: `/api/source`
  serves whatever path the client asks for, resolved with the same
  local-machine trust the TUI has — absolute paths included. On localhost
  that is a debugger reading your own files; through a tunnel it is anyone
  with the URL reading any file this machine's user can. Share for a live
  demo with people the user trusts, and tear down as soon as it is over.
- some corporate and DNS-filtered networks block `trycloudflare.com`, so if the
  recipient sees nothing at all, that is the likely cause rather than a bug

Then leave the tunnel running in the background and stay available. Do not exit
the process or clean up unless the user asks.

## Step 6 — Tear down

When the user says they are done, stop the tunnel and `serve.exe`, and confirm
the link is now dead. Do not leave either running after the user has moved on —
an abandoned tunnel is a live public window into this machine.

## Known limits worth mentioning if they come up

- **200 concurrent requests.** Quick tunnels return HTTP 429 past that. Only
  relevant with many simultaneous viewers or a very chatty UI.
- **No uptime guarantee.** Cloudflare positions quick tunnels as a testing and
  development tool.

## What not to do

Do not put a different server in front of the build output or serve any
directory of this repo — `serve.exe` embeds everything the browser needs, and
anything more served is surface the user has not thought about. Do not widen
the server past loopback; the tunnel is the one doorway, and killing it is
the one switch that ends the share.

If the user asks for a permanent link instead, this skill is the wrong tool —
say so rather than improvising, since permanence means hosting the dump and
sources somewhere rather than streaming them from this machine.
