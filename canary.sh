#!/usr/bin/env bash
# The outer shell of the visual replay debugger.
#
#   ./canary.sh [--web] path/to/program.ml [args...]
#
# Pipeline: 1. build the forked compiler if the pinned commit changed;
# 2. assemble a toolchain (the fork's compiler over an opam switch's
# libraries); 3. compile with -visual-replay -- in place if the file is
# already a dune target, else wrapped in a scratch project -- while 3b
# profiles an uninstrumented twin in the background; 4. run it, events
# going to the dump; 5. exec the TUI on the dump -- or, with --web,
# serve the browser interface behind a shareable trycloudflare.com URL
# instead of the TUI, until Ctrl-C ends the share.
#
# Artifacts: _vreplay/<program-name>/; shared toolchain:
# _vreplay/.toolchain/. Knobs: VREPLAY_SWITCH (library switch, default
# jsip-vreplay), VREPLAY_TARGET (executable when a dune file declares
# several), VREPLAY_DUMP_ONLY (stop once the dump is on disk),
# VREPLAY_WEB_PORT (the web server's port, default 8080),
# COMPILER_DIR / INTERFACE_DIR (override the submodule checkouts).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compiler="${COMPILER_DIR:-$root/jsip-debugger-compiler}"
interface="${INTERFACE_DIR:-$root/jsip-debugger-interface}"

say() { printf 'canary: %s\n' "$*"; }
die() {
  printf 'canary: error: %s\n' "$*" >&2
  exit 1
}

web=""
if [ "${1:-}" = "--web" ]; then
  web=1
  shift
fi
[ $# -ge 1 ] ||
  die "usage: ./canary.sh [--web] path/to/program.ml [args...]
             ./canary.sh [--web] path/to/program-dir [args...]
             ./canary.sh [--web] path/to/target.exe [args...]
--web serves the replay behind a shareable public URL instead of
opening the TUI; Ctrl-C ends the share"
prog="${1%/}"
shift
prog_args=("$@")
# A loose .ml is wrapped in a scratch project; a directory is the same
# but multi-file, entering at main.ml; a .exe names a dune target.
if [ -d "$prog" ]; then
  [ -f "$prog/main.ml" ] ||
    die "a multi-file program needs a main.ml: $prog"
  prog="$(cd "$prog" && pwd)"
  main_src="$prog/main.ml"
else
  case "$prog" in
  *.ml)
    [ -f "$prog" ] || die "no such file: $prog"
    ;;
  *.exe)
    [ -d "$(dirname "$prog")" ] || die "no such directory: $(dirname "$prog")"
    ;;
  *)
    die "expected an .ml file, a directory, or a dune .exe target, \
got: $prog"
    ;;
  esac
  prog="$(cd "$(dirname "$prog")" && pwd)/$(basename "$prog")"
  main_src="$prog"
fi
[ -f "$compiler/configure" ] && [ -f "$interface/dune-project" ] ||
  die "submodules missing; run: git submodule update --init --recursive"
# Fail on a missing cloudflared now, not after a four-minute build.
[ -z "$web" ] || command -v cloudflared >/dev/null 2>&1 ||
  die "--web needs cloudflared; see README.md (Sharing the replay on the web)"

name="$(basename "$prog")"
name="${name%.ml}"
name="${name%.exe}"
work="$root/_vreplay/$name"
dump="$work/$name.dump"
mkdir -p "$work"

# --- 1. the forked compiler -------------------------------------------------
# Bytecode `make world` (the fork has native support now; the pipeline
# has not moved onto it), installed to its own _install prefix so tools
# see an installed-shaped lib dir, and redone when the pinned commit
# changes (the .built-rev stamp). Whether the fork is CORRECT is the
# fork's own question -- its golden-dump suite lives in its repo and runs
# in its CI. All this asks is whether the build produced the pieces the
# pipeline goes on to use.
prefix="$compiler/_install"
ocamlrun="$prefix/bin/ocamlrun"

want_rev="$(git -C "$compiler" rev-parse HEAD)"
built_rev="$(cat "$prefix/.built-rev" 2>/dev/null || true)"

if [ "$built_rev" != "$want_rev" ] || ! [ -f "$compiler/vreplay/src/vreplay.cma" ]; then
  say "building the forked compiler at ${want_rev:0:12} (~4 min from scratch)"
  # A rev bump is not safely incremental, so the build starts from a
  # clean tree. make only compares the mtimes of prerequisites that still
  # EXIST, so a source REMOVED from a list leaves everything generated
  # from that list stale for good. The fork moved caml_wire_emit and
  # caml_wire_traverse out of the runtime into the vreplay C stubs; a
  # carried-over runtime/primitives keeps naming them, prims.c inherits
  # it, and linking runtime/ocamlrun dies on two undefined references.
  # Deleting just those two gets one step further and then dies in
  # ocamlmklib with "unknown C primitive", the bytecode tools having been
  # linked against the old table themselves. Nothing short of this makes
  # .built-rev mean what it says. distclean needs a configured tree and
  # takes Makefile.config with it, so it is tolerated and reconfigure
  # follows.
  (cd "$compiler" && [ -f Makefile.config ] && make distclean) >/dev/null 2>&1 ||
    true
  # `make install` aborts at tools/ocamldep.opt on a bytecode-only tree,
  # after everything we need is in place: tolerate it and hand-finish.
  # The old _install goes first so the new one cannot inherit a previous
  # rev's files under names this one no longer installs -- +vreplay
  # resolves into _install, so a leftover vreplay.cmi there would shadow
  # the freshly built library.
  (cd "$compiler" &&
    rm -rf _install &&
    { [ -f Makefile.config ] || ./configure -C --prefix "$compiler/_install"; } &&
    make -j"$(nproc)" world &&
    { make install || true; } &&
    ln -sf ocamlc.byte _install/bin/ocamlc &&
    ln -sf ocamldep.byte _install/bin/ocamldep &&
    cp -p Makefile.config _install/lib/ocaml/Makefile.config &&
    [ -f _install/bin/ocamlrun ] &&
    [ -f _install/lib/ocaml/stdlib.cma ] &&
    [ -f _install/lib/ocaml/runtime-launch-info ] &&
    [ -f vreplay/src/vreplay.cma ] &&
    [ -f vreplay/src/libvreplaybyt.a ]) \
    >"$root/_vreplay/compiler-build.log" 2>&1 ||
    die "compiler build failed; see _vreplay/compiler-build.log"
  printf '%s\n' "$want_rev" >"$prefix/.built-rev"
fi

# --- 2. the toolchain -------------------------------------------------------
# A compiler reads only .cmi files written by its own exact version (the
# fork stamps Caml1999I037, the OxCaml switch Caml1999I578), so linking
# Core needs a switch whose libraries were compiled BY the fork's
# version: $switch. Its ocamlc and libcamlrun are older, so take only
# its libraries and splice the fork's compiler and runtime over the top:
#
#   OCAMLLIB   private copy of the switch's lib/ocaml carrying the
#              fork's libcamlrun* and vreplay/* -- including the vreplay
#              stubs (caml_wire_emit and the walker live there now, not
#              in the runtime).
#   OCAMLPATH  the switch's lib (Core, Async, the ppx drivers)
#   PATH       the shims, then a mirror of the inherited PATH with every
#              OCaml binary left out. dune probes PATH for ocamlopt (it
#              does not believe ocamlc -config), and a stray one -- the
#              system 4.14 in /usr/bin -- would be handed -visual-replay;
#              /usr/bin itself must stay for gcc and ld.
#
# -visual-replay puts +vreplay on the load path, and + resolves against
# OCAMLLIB, so a foreign project builds with no added flags.
switch="${VREPLAY_SWITCH:-jsip-vreplay}"
swdir="$(opam var --switch="$switch" prefix 2>/dev/null || true)"
[ -n "$swdir" ] && [ -d "$swdir/lib/ocaml" ] ||
  die "no opam switch named '$switch'. Instrumented programs link their \
libraries from a switch built by the fork's own compiler version; set \
VREPLAY_SWITCH to name a different one. To build it: opam switch create \
$switch --empty, then pin ocaml-variants to the fork and install core \
and async."

tc="$root/_vreplay/.toolchain"
ocamllib="$tc/ocamllib"
shims="$tc/bin"
tc_want="$want_rev $swdir"

if [ "$(cat "$tc/.stamp" 2>/dev/null || true)" != "$tc_want" ]; then
  say "assembling the toolchain (fork ${want_rev:0:12} over switch $switch)"
  rm -rf "$tc"
  mkdir -p "$shims"
  cp -a "$swdir/lib/ocaml" "$ocamllib"
  cp -p "$compiler"/runtime/libcamlrun*.a "$ocamllib/"
  cp -p "$compiler"/runtime/libcamlrun*.so "$ocamllib/" 2>/dev/null || true
  mkdir -p "$ocamllib/vreplay"
  cp -p "$compiler"/vreplay/src/*.cmi "$compiler"/vreplay/src/*.cma \
    "$compiler"/vreplay/src/libvreplaybyt.a "$ocamllib/vreplay/"
  cp -p "$compiler"/vreplay/src/dllvreplaybyt*.so "$ocamllib/stublibs/" \
    2>/dev/null || true

  # Config queries answer for the fork, without -visual-replay (ocamlc
  # rejects it alongside -config). native_compiler is overridden to
  # false: this tree built no ocamlopt, and the honest answer keeps dune
  # on the bytecode path, where .exe is a self-contained -custom link.
  cat >"$shims/ocamlc" <<EOF
#!/bin/sh
case " \$* " in
*" -config-var native_compiler "*) echo false; exit 0 ;;
esac
for a in "\$@"; do
  case "\$a" in
  -config)
    "$ocamlrun" "$prefix/bin/ocamlc" "\$@" |
      sed 's/^native_compiler: true\$/native_compiler: false/'
    exit \$?
    ;;
  -config-var | -version | -vnum | -where)
    exec "$ocamlrun" "$prefix/bin/ocamlc" "\$@" ;;
  esac
done
exec "$ocamlrun" "$prefix/bin/ocamlc" -visual-replay "\$@"
EOF
  chmod +x "$shims/ocamlc"
  ln -sf ocamlc "$shims/ocamlc.byte"
  for tool in "$swdir"/bin/*; do
    case "$(basename "$tool")" in
    ocamlc | ocamlc.byte) continue ;;
    esac
    ln -sf "$tool" "$shims/$(basename "$tool")"
  done

  # The rest of the world, minus every OCaml binary; earlier PATH
  # entries win.
  mkdir -p "$tc/binsafe"
  IFS=: read -ra path_entries <<<"$PATH"
  for entry in "${path_entries[@]}"; do
    [ -d "$entry" ] || continue
    for tool in "$entry"/*; do
      base="${tool##*/}"
      case "$base" in ocaml* | dune) continue ;; esac
      if [ -x "$tool" ] && [ ! -e "$tc/binsafe/$base" ]; then
        ln -s "$tool" "$tc/binsafe/$base"
      fi
    done
  done
  printf '%s\n' "$tc_want" >"$tc/.stamp"
fi

tc_path="$shims:$tc/binsafe"

# The instrumented build runs under these; the interface build later must
# not, so they are passed per-command rather than exported here.
tc_env=(
  "OCAMLLIB=$ocamllib"
  "OCAMLPATH=$swdir/lib"
  "OCAMLFIND_CONF=$swdir/lib/findlib.conf"
  "CAML_LD_LIBRARY_PATH=$ocamllib/stublibs:$swdir/lib/stublibs"
  "PATH=$tc_path"
)

# --- 3. compile with -visual-replay -----------------------------------------
# Names declared by (executable (name x)) / (executables (names x y)) --
# enough of a parser for the shapes dune files actually take.
dune_exe_names() {
  awk '
    /\(executables?([ \t(]|$)/ { in_exe = 1 }
    in_exe && match($0, /\(names?[ \t]+[^)]*\)/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/\(names?[ \t]+/, "", s)
      sub(/\)$/, "", s)
      print s
      in_exe = 0
    }
  ' "$1"
}

progdir="$(dirname "$prog")"
projroot=""
if [ -f "$progdir/dune" ]; then
  d="$progdir"
  while [ "$d" != "/" ]; do
    if [ -f "$d/dune-project" ]; then
      projroot="$d"
      break
    fi
    d="$(dirname "$d")"
  done
fi
case "$prog" in
*.exe)
  [ -n "$projroot" ] ||
    die "$prog names a dune target, but $progdir has no dune file with a \
dune-project above it. Pass the .ml instead to have it wrapped in a \
scratch project."
  ;;
esac

# Kept between runs so dune stays incremental. The toolchain is the one
# thing dune cannot see changing, so the stamp guards it: a new compiler
# or switch invalidates everything.
builddir="$work/build"
if [ "$(cat "$work/.toolchain-stamp" 2>/dev/null || true)" != "$tc_want" ]; then
  rm -rf "$builddir"
fi
mkdir -p "$builddir"
printf '%s\n' "$tc_want" >"$work/.toolchain-stamp"

if [ -n "$projroot" ]; then
  # Project mode: build in place so the file keeps its libraries, with
  # artifacts in our own --build-dir, not the checkout's _build.
  reldir="${progdir#"$projroot"/}"
  [ "$reldir" = "$progdir" ] && reldir="."
  mapfile -t cands < <(dune_exe_names "$progdir/dune")
  target="${VREPLAY_TARGET:-}"
  # An .exe named the target outright; an .ml is matched to an
  # executable by name, else by being the only one declared.
  case "$prog" in
  *.exe) [ -n "$target" ] || target="$name" ;;
  esac
  if [ -z "$target" ]; then
    for c in ${cands[*]+"${cands[@]}"}; do
      [ "$c" = "$name" ] && target="$c"
    done
  fi
  [ -n "$target" ] || [ "${#cands[@]}" -ne 1 ] || target="${cands[0]}"
  [ -n "$target" ] ||
    die "cannot tell which executable $prog belongs to. $progdir/dune \
declares: ${cands[*]:-none}. Set VREPLAY_TARGET to one of them."

  say "compiling $projroot with -visual-replay ($reldir/$target.exe)"
  # VREPLAY_FILE=/dev/null keeps the ppx drivers (themselves
  # instrumented) from scattering vreplay.dump files during the build.
  env "${tc_env[@]}" VREPLAY_FILE=/dev/null \
    dune build --root "$projroot" --build-dir "$builddir" --no-config \
    "$reldir/$target.exe" || die "instrumented build failed"
  exe="$builddir/default/$reldir/$target.exe"
  source_root="$projroot"
else
  # Standalone mode. A directory enters at main.ml; a single file keeps
  # its own name as the module when valid, else "main".
  if [ -d "$prog" ]; then
    module=main
  else
    case "$name" in
    [a-z_]*[!a-zA-Z0-9_]* | [!a-z_]*) module=main ;;
    *) module="$name" ;;
    esac
  fi

  # Libraries inferred from the program's opens; any of them implies
  # ppx_jane too.
  libs=""
  for lib in base core core_unix async; do
    case "$lib" in
    core_unix) mod=Core_unix ;;
    *) mod="$(printf '%s' "$lib" | sed 's/^./\U&/')" ;;
    esac
    grep -rqE "^[[:space:]]*open!?[[:space:]]+$mod\b" "$prog" &&
      libs="$libs $lib"
  done

  say "compiling $prog with -visual-replay (scratch project${libs:+, linking$libs})"
  if [ -d "$prog" ]; then
    cp "$prog"/*.ml "$builddir/"
    cp "$prog"/*.mli "$builddir/" 2>/dev/null || true
  else
    cp "$prog" "$builddir/$module.ml"
  fi
  cat >"$builddir/dune-project" <<'EOF'
(lang dune 3.0)
EOF
  # (modes byte) still yields a .exe: a -custom link with the runtime
  # and any C stubs baked in.
  {
    printf '(executable\n (name %s)\n (modes byte)\n' "$module"
    if [ -n "$libs" ]; then
      printf ' (libraries%s)\n (preprocess (pps ppx_jane))\n' "$libs"
    fi
    printf ' (flags (:standard -visual-replay)))\n'
  } >"$builddir/dune"

  env "${tc_env[@]}" VREPLAY_FILE=/dev/null \
    dune build --root "$builddir" --no-config "./$module.exe" ||
    die "instrumented build failed"
  exe="$builddir/_build/default/$module.exe"
  source_root="$builddir/_build/default"
fi

# --- 3b. the perf job -------------------------------------------------------
# Heat has to come from the program as it really is: a twin with no
# -visual-replay in it, built natively on the ordinary switch and
# recorded under perf -- its own build dir, toolchain and process,
# running alongside the capture. The main line waits for it before the
# TUI and reports what it managed.
perfdir="$work/perf"
rm -rf "$perfdir"
mkdir -p "$perfdir"
heat="$work/heat.sexp"
rm -f "$heat"
heat_switch="${JSIP_HEAT_SWITCH:-5.2.0+ox}"

# The entry module breaks ties in the report between a function of the
# program's and a same-named library one.
if [ -n "$projroot" ]; then entry_module="${target^}"; else entry_module="${module^}"; fi

# Runs in the background; reports by leaving a line in $perfdir/verdict.
perf_job() {
  verdict() { printf '%s\n' "$*" >"$perfdir/verdict"; }

  command -v perf >/dev/null 2>&1 || {
    verdict "no heat profile: perf is not installed"
    return 0
  }
  opam exec --switch "$heat_switch" -- ocamlopt -version >/dev/null 2>&1 || {
    verdict "no heat profile: opam switch $heat_switch has no ocamlopt"
    return 0
  }

  local twin_exe=""
  if [ -n "$projroot" ]; then
    # Own --build-dir: the twin and the instrumented build stay apart.
    if opam exec --switch "$heat_switch" -- dune build --root "$projroot" \
      --build-dir "$perfdir/build" --no-config "$reldir/$target.exe" \
      >"$perfdir/twin-build.log" 2>&1; then
      twin_exe="$perfdir/build/default/$reldir/$target.exe"
    fi
  else
    mkdir -p "$perfdir/build"
    if [ -d "$prog" ]; then
      cp "$prog"/*.ml "$perfdir/build/"
      cp "$prog"/*.mli "$perfdir/build/" 2>/dev/null || true
    else
      cp "$prog" "$perfdir/build/$module.ml"
    fi
    printf '(lang dune 3.0)\n' >"$perfdir/build/dune-project"
    {
      printf '(executable\n (name %s)\n (modes native)\n' "$module"
      # the same libraries the instrumented build got, or the twin will
      # not compile the moment a program opens Core
      [ -n "$libs" ] &&
        printf ' (libraries%s)\n (preprocess (pps ppx_jane))\n' "$libs"
      printf ')\n'
    } >"$perfdir/build/dune"
    if opam exec --switch "$heat_switch" -- dune build \
      --root "$perfdir/build" --no-config "./$module.exe" \
      >"$perfdir/twin-build.log" 2>&1; then
      twin_exe="$perfdir/build/_build/default/$module.exe"
    fi
  fi
  [ -n "$twin_exe" ] || {
    verdict "no heat profile: the twin's native build failed (see ${perfdir#"$root/"}/twin-build.log)"
    return 0
  }

  # Record the twin looped, not once: these programs are milliseconds
  # long, and a single recording never clears the distiller's sample
  # floor. The loop is sized by timing a bare run -- a recorded one
  # carries perf's own startup and would size it far too small.
  local start_ms elapsed_ms iters status
  start_ms=$(date +%s%3N)
  "$twin_exe" ${prog_args[@]+"${prog_args[@]}"} >/dev/null 2>&1 || true
  elapsed_ms=$(($(date +%s%3N) - start_ms))
  # ~10s of looped wall time; part of each iteration is process startup,
  # so budget generously.
  [ "$elapsed_ms" -lt 1 ] && elapsed_ms=1
  iters=$((10000 / elapsed_ms + 50))
  [ "$iters" -gt 200000 ] && iters=200000

  cat >"$perfdir/loop.sh" <<'LOOP'
#!/bin/sh
n=$1
shift
i=0
while [ "$i" -lt "$n" ]; do
  "$@" >/dev/null 2>&1 || true
  i=$((i + 1))
done
LOOP
  chmod +x "$perfdir/loop.sh"
  perf record -F max -o "$perfdir/perf.data" -- \
    "$perfdir/loop.sh" "$iters" "$twin_exe" \
    ${prog_args[@]+"${prog_args[@]}"} \
    >/dev/null 2>"$perfdir/perf.log" || {
    verdict "no heat profile: perf record failed (see ${perfdir#"$root/"}/perf.log)"
    return 0
  }

  # --root . or dune walks up to an enclosing workspace (in a git
  # worktree, the parent clone).
  (cd "$root" && dune build --root . bin/perf_heat_interface.exe) \
    >"$perfdir/distiller-build.log" 2>&1 || {
    verdict "no heat profile: distiller build failed (see ${perfdir#"$root/"}/distiller-build.log)"
    return 0
  }

  distill() {
    perf report -i "$perfdir/perf.data" --stdio \
      --dsos "$(basename "$twin_exe")" --percent-limit 0 -F sample,sym \
      2>/dev/null |
      "$root/_build/default/bin/perf_heat_interface.exe" "$entry_module" "$heat"
  }

  status=0
  distill || status=$?

  # Exit 3 and a single source file: when a run does less work than
  # starting a process, every external-loop sample is runtime startup,
  # and only an in-process loop reaches the program's code. Wrapping
  # source costs generality, so it goes second and only for one file;
  # the line directive keeps symbols pointing at the real program.
  if [ "$status" -eq 3 ] && [ -z "$projroot" ] && [ ! -d "$prog" ]; then
    local loopdir="$perfdir/inproc"
    mkdir -p "$loopdir"
    {
      printf 'let () =\n'
      printf '  let n = int_of_string (Sys.getenv "JSIP_HEAT_ITERS") in\n'
      printf '  for _ = 1 to n do\n'
      printf '    let module _ = struct\n'
      printf '# 1 "%s.ml"\n' "$module"
      cat "$prog"
      printf '    end in ()\n'
      printf '  done\n'
    } >"$loopdir/$module.ml"
    printf '(lang dune 3.0)\n' >"$loopdir/dune-project"
    {
      printf '(executable\n (name %s)\n (modes native)\n' "$module"
      [ -n "$libs" ] &&
        printf ' (libraries%s)\n (preprocess (pps ppx_jane))\n' "$libs"
      printf ')\n'
    } >"$loopdir/dune"
    if opam exec --switch "$heat_switch" -- dune build --root "$loopdir" \
      --no-config "./$module.exe" >"$perfdir/inproc-build.log" 2>&1; then
      twin_exe="$loopdir/_build/default/$module.exe"
      if perf record -F max -o "$perfdir/perf.data" -- \
        env JSIP_HEAT_ITERS=200000 "$twin_exe" \
        >/dev/null 2>"$perfdir/perf.log"; then
        status=0
        distill || status=$?
      fi
    fi
  fi

  case "$status" in
  0) verdict "heat profile: ${heat#"$root/"} (recorded from the uninstrumented twin)" ;;
  3) verdict "no heat profile: the program's own code never accumulated enough samples -- too little of it runs to measure" ;;
  *) verdict "no heat profile: the distiller exited $status" ;;
  esac
}

say "perf job started (uninstrumented twin, native, switch $heat_switch)"
perf_job >"$perfdir/job.log" 2>&1 &
perf_job_pid=$!

# --- 4. run it, dump going to its own sink ----------------------------------
# Events go to VREPLAY_FILE; the program's own output stays on the
# terminal.
say "running $name (its output follows; replay events go to the dump)"
rm -f "$dump"
env "${tc_env[@]}" VREPLAY_FILE="$dump" \
  "$exe" ${prog_args[@]+"${prog_args[@]}"} ||
  die "instrumented program exited nonzero"
[ -s "$dump" ] ||
  die "the run produced no replay events. What is instrumented: calls \
involving a tracked container -- the stdlib's Map/Set/Queue/Hashtbl/\
Stack/Dynarray and Core's equivalents -- and each binding of a value \
whose type this program declares. An event rooted at a MUTATION needs a \
named identifier: Hashtbl.add tbl ... is recorded, Hashtbl.add t.field \
... is not"
say "dump captured: ${dump#"$root/"} ($(grep -c '(event ' "$dump") events)"

# --- 4b. the perf job reports back ------------------------------------------
wait "$perf_job_pid" 2>/dev/null || true
if [ -f "$perfdir/verdict" ]; then
  say "$(cat "$perfdir/verdict")"
else
  say "no heat profile: the perf job died (see ${perfdir#"$root/"}/job.log)"
fi

if [ -n "${VREPLAY_DUMP_ONLY:-}" ]; then
  say "VREPLAY_DUMP_ONLY set; stopping before the TUI. Replay it with:"
  say "  (cd $interface && dune build --root . app/bin/main.exe)"
  say "  $interface/_build/default/app/bin/main.exe \\"
  if [ -f "$heat" ]; then
    say "    -dump-file $dump -source-root $source_root \\"
    say "    -perf-file $heat"
  else
    say "    -dump-file $dump -source-root $source_root"
  fi
  exit 0
fi

# --- 5w. serve the replay behind a shareable URL ----------------------------
# The web server is self-contained (the js_of_ocaml client is embedded in
# serve.exe) and binds loopback only; a cloudflared quick tunnel is the
# one doorway in. It builds on the ordinary OxCaml switch -- the TUI's
# dependencies do not cover bonsai_web. The share replaces the TUI: the
# script stays in the foreground until Ctrl-C, and the exit trap tears
# the share down.
if [ -n "$web" ]; then
  web_switch="${JSIP_HEAT_SWITCH:-5.2.0+ox}"
  say "building the web interface (switch $web_switch)"
  (cd "$interface" && opam exec --switch "$web_switch" -- \
    dune build --root . app/web/server/serve.exe) ||
    die "web interface build failed. If libraries are missing: \
opam install --switch $web_switch -y bonsai_web async_js cohttp-async \
js_of_ocaml-ppx ppx_html"

  webdir="$work/web"
  rm -rf "$webdir"
  mkdir -p "$webdir"
  port="${VREPLAY_WEB_PORT:-8080}"
  serve_args=(-dump-file "$dump" -source-root "$source_root" -port "$port")
  [ -f "$heat" ] && serve_args+=(-perf-file "$heat")

  "$interface/_build/default/app/web/server/serve.exe" "${serve_args[@]}" \
    >"$webdir/serve.log" 2>&1 &
  serve_pid=$!
  tunnel_pid=""
  trap 'kill $serve_pid $tunnel_pid 2>/dev/null || true; rm -f "$webdir/url"' EXIT INT TERM
  while ! grep -q 'jsip web debugger' "$webdir/serve.log" 2>/dev/null; do
    kill -0 "$serve_pid" 2>/dev/null ||
      die "the web server died (port $port taken?); see ${webdir#"$root/"}/serve.log"
    sleep 0.2
  done

  # cloudflared prints the URL in its stderr banner. No URL in ~15s
  # usually means QUIC is blocked, and its own fallback takes over a
  # minute -- retry on http2 instead.
  # Sets $tunnel_pid and $url; must run in this shell, not a subshell,
  # or the trap and the final wait would have no pid to act on.
  url=""
  start_tunnel() {
    cloudflared tunnel --url "http://127.0.0.1:$port" --config /dev/null \
      --no-autoupdate "$@" >>"$webdir/tunnel.log" 2>&1 &
    tunnel_pid=$!
    local i
    for i in $(seq 1 75); do
      url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' \
        "$webdir/tunnel.log" 2>/dev/null | head -1)"
      [ -n "$url" ] && return 0
      kill -0 "$tunnel_pid" 2>/dev/null || return 1
      sleep 0.2
    done
    kill "$tunnel_pid" 2>/dev/null || true
    return 1
  }

  say "opening the tunnel"
  start_tunnel || {
    say "no URL after 15s (QUIC likely blocked); retrying over http2"
    start_tunnel --protocol http2
  } || die "cloudflared could not open a tunnel; see ${webdir#"$root/"}/tunnel.log"

  printf '%s\n' "$url" >"$webdir/url"
  say "shareable link: $url"
  say "  (kept in ${webdir#"$root/"}/url while the share is up)"
  say "  unguessable, not private: anyone with the link can use the replay,"
  say "  and its api/source lets them read files off this machine"
  say "  a viewer who sees nothing is likely on a network blocking trycloudflare.com"
  say "sharing (Ctrl-C ends the share)"
  wait "$serve_pid" "$tunnel_pid" || true
  exit 0
fi

# --- 5. hand the dump to the interface --------------------------------------
# Built with this repo's own toolchain -- deliberately no tc_env. Dump
# source paths are relative to where the compiler ran: the project root
# or the scratch build context.
say "building the interface"
(cd "$interface" && dune build --root . app/bin/main.exe) ||
  die "interface build failed"
app_args=(-dump-file "$dump" -source-root "$source_root")
# -perf-file only if this interface advertises it; older pins reject
# unknown options.
if [ -f "$heat" ] &&
  "$interface/_build/default/app/bin/main.exe" -help 2>&1 |
  grep -q -- "-perf-file"; then
  app_args+=(-perf-file "$heat")
elif [ -f "$heat" ]; then
  say "note: this interface has no -perf-file; heat profile written but not shown"
fi
say "replaying in the TUI (q quits, arrows step)"
exec "$interface/_build/default/app/bin/main.exe" "${app_args[@]}"
