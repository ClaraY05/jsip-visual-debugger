#!/usr/bin/env bash
# The outer shell of the visual replay debugger.
#
#   ./cool_name.sh path/to/program.ml [args...]
#
# Pipeline:
#   1. build the forked compiler if needed (bytecode world; redone
#      whenever the pinned submodule commit changes)
#   2. assemble a toolchain -- the fork's compiler over an opam switch's
#      libraries -- so instrumented programs can link Core and Async
#   3. compile the program with -visual-replay through dune
#   4. run the instrumented binary -- replay events go to the dump file
#      via VREPLAY_FILE, the program's own output to the terminal
#   5. build the interface and replace this process with the TUI,
#      replaying the dump
#
# Step 3 has two modes, chosen by looking at where the file lives:
#
#   project     the file already is a dune target (there is a `dune`
#               beside it), so it is built where it stands and keeps its
#               own libraries, ppx and dependencies.  This is how a whole
#               project -- jsip-exchange, say -- comes in.
#   standalone  a loose .ml file, wrapped in a scratch dune project.
#
# Artifacts land in _vreplay/<program-name>/ (gitignored); the toolchain
# is shared across programs in _vreplay/.toolchain/.
#
# Knobs: VREPLAY_SWITCH picks the library switch (default jsip-vreplay),
# VREPLAY_TARGET names the executable when a dune file declares several,
# VREPLAY_DUMP_ONLY stops after step 4 with the dump on disk.
set -euo pipefail

# COMPILER_DIR / INTERFACE_DIR override the submodule checkouts, e.g. to
# run against standalone clones that are ahead of the pinned commits.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compiler="${COMPILER_DIR:-$root/jsip-debugger-compiler}"
interface="${INTERFACE_DIR:-$root/jsip-debugger-interface}"

say() { printf 'cool_name: %s\n' "$*"; }
die() {
  printf 'cool_name: error: %s\n' "$*" >&2
  exit 1
}

[ $# -ge 1 ] ||
  die "usage: ./cool_name.sh path/to/program.ml [args...]
             ./cool_name.sh path/to/program-dir [args...]
             ./cool_name.sh path/to/target.exe [args...]"
prog="${1%/}"
shift
prog_args=("$@")
# Three shapes. A loose .ml is wrapped in a scratch project; a directory
# is the same but multi-file, its entry point main.ml and the rest
# ordinary dependency modules dune sorts out; a .exe names a dune target
# outright, which is what a project that already has a `dune` wants.
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

name="$(basename "$prog")"
name="${name%.ml}"
name="${name%.exe}"
work="$root/_vreplay/$name"
dump="$work/$name.dump"
mkdir -p "$work"

# --- 1. the forked compiler -------------------------------------------------
# Bytecode only: native has never built on the vreplay branches, so it's
# `make world`, not `world.opt`. The fork is configured and installed to
# its own _install prefix -- the layout the fork's team uses -- so that
# tools (dune especially) see an installed-shaped lib dir. The build is
# validated with one of the fork's own golden-dump tests, and redone
# whenever the pinned submodule commit changes (the .built-rev stamp).
prefix="$compiler/_install"
ocamlrun="$prefix/bin/ocamlrun"

# Where the fork keeps its vreplay library and its golden-dump tests. The
# fork's PR #23 moved the library under vreplay/src and the tests from
# testing/ to vreplay/tests; earlier revs have them at vreplay/ and
# testing/. Probe a tracked SOURCE file, never a build product: checking
# out across that move leaves the pre-move .cma, .cmi and .a behind at
# vreplay/ as untracked litter, so a probe on artifacts reads the old
# layout as current and hands the toolchain a library from whichever rev
# was built last.
if [ -f "$compiler/vreplay/src/vreplay.ml" ]; then
  vreplay_lib="$compiler/vreplay/src"
  vreplay_tests="vreplay/tests/run_tests.sh"
else
  vreplay_lib="$compiler/vreplay"
  vreplay_tests="testing/run_tests.sh"
fi

want_rev="$(git -C "$compiler" rev-parse HEAD)"
built_rev="$(cat "$prefix/.built-rev" 2>/dev/null || true)"

if [ "$built_rev" != "$want_rev" ] || ! [ -f "$vreplay_lib/vreplay.cma" ]; then
  say "building the forked compiler at ${want_rev:0:12} (~4 min from scratch)"
  # A rev bump is not safely incremental here, so start from a clean
  # tree. make compares mtimes of prerequisites that still EXIST, which
  # means a source REMOVED from a list leaves everything generated from
  # that list stale forever. The fork moved caml_wire_emit and
  # caml_wire_traverse out of the runtime into the vreplay C stubs, and a
  # tree that crosses that move regenerates neither runtime/primitives
  # nor runtime/prims.c: linking runtime/ocamlrun then dies on two
  # undefined references, and every bytecode tool already linked against
  # the old primitive table dies with "unknown C primitive". Nothing
  # short of a clean build makes .built-rev mean what it says.
  (cd "$compiler" && [ -f Makefile.config ] && make distclean) >/dev/null 2>&1 ||
    true
  # The previous rev's install prefix has to go too, and distclean does
  # not know about it. -visual-replay resolves +vreplay against the
  # CONFIGURED stdlib -- _install/lib/ocaml -- ahead of run_tests.sh's -I
  # on the source dir, so a stale installed vreplay.cmi shadows the
  # freshly built one during the validation run. Harmless while the
  # snapshot signature holds still; the moment a rev changes it,
  # map_basic dies on a phantom arity error ("applied to too many
  # arguments").
  rm -rf "$prefix"
  # `make install` is expected to die partway: on a bytecode-only tree it
  # aborts at tools/ocamldep.opt, after everything we need (runtime,
  # stdlib, byte binaries) is already in place. Tolerate it, hand-finish
  # the names it never got to, and verify the pieces that matter.
  (cd "$compiler" &&
    { [ -f Makefile.config ] || ./configure -C --prefix "$compiler/_install"; } &&
    make -j"$(nproc)" world &&
    "$vreplay_tests" map_basic &&
    { make install || true; } &&
    ln -sf ocamlc.byte _install/bin/ocamlc &&
    ln -sf ocamldep.byte _install/bin/ocamldep &&
    cp -p Makefile.config _install/lib/ocaml/Makefile.config &&
    [ -f _install/bin/ocamlrun ] &&
    [ -f _install/lib/ocaml/stdlib.cma ] &&
    [ -f _install/lib/ocaml/runtime-launch-info ]) \
    >"$root/_vreplay/compiler-build.log" 2>&1 ||
    die "compiler build failed; see _vreplay/compiler-build.log"
  printf '%s\n' "$want_rev" >"$prefix/.built-rev"
fi

# --- 2. the toolchain -------------------------------------------------------
# A compiler can only read .cmi files written by its own exact version, in
# either direction -- there is no forward compatibility to lean on. The
# fork stamps Caml1999I037, the OxCaml switch this repo is otherwise built
# with stamps Caml1999I578, and neither reads the other. So linking Core
# into an instrumented program means a switch whose Core was compiled BY
# the fork's version. That is $switch.
#
# Its own ocamlc is older than the pinned submodule (no Core catalogue)
# and its libcamlrun.a is the matching older C walker, so we take only its
# *libraries* and splice the fork's compiler and runtime over the top:
#
#   OCAMLLIB   a private copy of the switch's lib/ocaml carrying the
#              fork's libcamlrun*.{a,so} and vreplay/*. Pairing the fork's
#              OCaml-side vreplay with the switch's older C walker links
#              clean and then segfaults on the first event, so these two
#              have to move together.
#   OCAMLPATH  the switch's lib, where Core, Async and the ppx drivers are
#   PATH       the shims, then a mirror of the inherited PATH with every
#              OCaml binary left out. ocamlc is the fork's with
#              -visual-replay forced on; the rest of the toolchain is
#              symlinked from the switch, which needs no instrumenting.
#
# That mirror is what makes the shim airtight. dune decides native is
# available by looking for an ocamlopt on PATH -- it does not believe
# ocamlc -config's native_compiler, which we answer honestly -- and the
# fork is bytecode-only, so any stray ocamlopt anywhere on the path gets
# picked up and handed -visual-replay, which it does not understand.
# There is a system OCaml 4.14 in /usr/bin on this machine that does
# exactly that. Dropping /usr/bin wholesale is not an option (gcc and ld
# live there), so the mirror keeps everything except ocaml*.
#
# -visual-replay puts +vreplay on the load path itself (compmisc.ml), and
# + resolves against OCAMLLIB, so vreplay/ living there is what lets a
# project build with no added flags -- we cannot edit someone else's dune.
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
  cp -p "$vreplay_lib"/*.cmi "$vreplay_lib"/*.cma "$ocamllib/vreplay/"
  # The C walker moved out of libcamlrun into its own stubs archive
  # (snapshot.c -> libvreplaybyt). vreplay.cma records -cclib
  # -lvreplaybyt, which a -custom link resolves against the load path, so
  # the archive has to sit beside the cma; the dll is the non-custom
  # equivalent and lives with the other stub dlls. Older revs have
  # neither file -- their walker still rides in the libcamlrun overlay
  # copied just above -- hence the tolerated misses.
  cp -p "$vreplay_lib"/lib*.a "$ocamllib/vreplay/" 2>/dev/null || true
  cp -p "$vreplay_lib"/dll*.so "$ocamllib/stublibs/" 2>/dev/null || true

  # Config probes have to answer for the compiler dune is about to drive,
  # and must not carry -visual-replay -- it is not a config query, and
  # ocamlc rejects it alongside -config.
  #
  # native_compiler is the one answer we override. The fork's configure
  # leaves it true, but `make world` is bytecode-only and never produces
  # an ocamlopt, so dune takes the config at its word, goes looking for
  # one, and finds whatever stray ocamlopt is on the system -- which then
  # chokes on -visual-replay. Saying false is the honest answer for what
  # this toolchain can actually do, and puts dune on the bytecode path,
  # where .exe becomes a self-contained -custom executable.
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

  # The rest of the world, minus every OCaml binary. Earlier PATH entries
  # win, as they would have on the real path.
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
# Names declared by (executable (name x)) / (executables (names x y)).
# Enough of a parser for the shape dune files actually take: the stanza
# head, then a (name ...) field somewhere inside it.
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

# Kept between runs so dune can be incremental -- a second look at the
# same program is worth seconds, not a rebuild. The toolchain is the one
# thing dune cannot see changing underneath it, so that is what the stamp
# guards: a new compiler or a new switch invalidates every artifact.
builddir="$work/build"
if [ "$(cat "$work/.toolchain-stamp" 2>/dev/null || true)" != "$tc_want" ]; then
  rm -rf "$builddir"
fi
mkdir -p "$builddir"
printf '%s\n' "$tc_want" >"$work/.toolchain-stamp"

if [ -n "$projroot" ]; then
  # Project mode. Build in place so the file keeps its libraries, but send
  # the artifacts to our own --build-dir: an instrumented _build is not
  # something to leave behind in someone else's checkout.
  reldir="${progdir#"$projroot"/}"
  [ "$reldir" = "$progdir" ] && reldir="."
  mapfile -t cands < <(dune_exe_names "$progdir/dune")
  target="${VREPLAY_TARGET:-}"
  # An .exe argument named the target outright; an .ml has to be traced
  # back to the executable that includes it -- by name if the dune file
  # declares one that matches, otherwise by there being only one.
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
  # VREPLAY_FILE at build time keeps the ppx drivers -- themselves built
  # by the instrumenting compiler -- from scattering vreplay.dump files,
  # which is where the runtime writes when the variable is unset.
  env "${tc_env[@]}" VREPLAY_FILE=/dev/null \
    dune build --root "$projroot" --build-dir "$builddir" --no-config \
    "$reldir/$target.exe" || die "instrumented build failed"
  exe="$builddir/default/$reldir/$target.exe"
  source_root="$projroot"
else
  # Standalone mode. A directory keeps its own module names and enters at
  # main.ml; a single file's scratch module keeps the program's own name
  # when that is a valid module name (so the TUI's source pane shows e.g.
  # map_demo.ml), and falls back to "main" otherwise.
  if [ -d "$prog" ]; then
    module=main
  else
    case "$name" in
    [a-z_]*[!a-zA-Z0-9_]* | [!a-z_]*) module=main ;;
    *) module="$name" ;;
    esac
  fi

  # Libraries the program opens. Anything Jane Street here is ppx_jane
  # territory too: the deriving attributes are common enough in such
  # programs that leaving the driver out is the surprising choice.
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
  # (modes byte) says out loud what the toolchain can do. dune still
  # gives us a .exe from it -- a -custom link with the runtime and any C
  # stubs baked in, which is what we want to run.
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
# A heat profile has to come from the program as it really is, so this
# builds a second copy with no -visual-replay in it, natively, on the
# ordinary switch, and records that under perf. It is a separate job in
# every sense: its own build directory, its own toolchain, and its own
# process, running alongside the instrumented capture rather than after
# it. The main line waits for it just before opening the TUI and reports
# whatever it managed.
#
# It replaces two limitations. The old stage wrapped the program's own
# source text in an in-process loop to accumulate samples, which meant it
# could not touch a project built in place -- so for anything like the
# exchange the profile had to be recorded by hand. Looping the twin from
# the outside needs no source rewriting, so a multi-file program and
# somebody else's dune project work the same way one file does.
perfdir="$work/perf"
rm -rf "$perfdir"
mkdir -p "$perfdir"
heat="$work/heat.sexp"
rm -f "$heat"
heat_switch="${JSIP_HEAT_SWITCH:-5.2.0+ox}"

# The entry module breaks ties in the report between a function of the
# program's and a same-named library one.
if [ -n "$projroot" ]; then entry_module="${target^}"; else entry_module="${module^}"; fi

# Everything below runs in the background; it says what happened by
# leaving a line in $perfdir/verdict, which the main line prints once the
# instrumented run has had the terminal to itself.
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
    # Its own --build-dir again, so the twin and the instrumented build
    # never see each other's artifacts and the checkout keeps its own.
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

  # Record the twin looped, not run once. perf attributes percentages by
  # sampling thousands of times a second, and every program here is
  # milliseconds long -- the exchange's twin is 20ms, the whole point of
  # the 11s instrumented run being instrumentation overhead. A single
  # recording of that yields a handful of samples and the distiller
  # rightly refuses it, so there is no reason to spend one first.
  #
  # Time a bare run to size the loop. Not a recorded one: perf's own
  # startup is tens of milliseconds and would make the program look far
  # slower than it is, sizing the loop far too small.
  local start_ms elapsed_ms iters status
  start_ms=$(date +%s%3N)
  "$twin_exe" ${prog_args[@]+"${prog_args[@]}"} >/dev/null 2>&1 || true
  elapsed_ms=$(($(date +%s%3N) - start_ms))
  # Aim for ~10s of looped wall time. Some of each iteration is process
  # startup rather than the program's own code, so the useful sample
  # yield is a fraction of that -- budget generously.
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

  # --root . or dune walks up to whatever workspace encloses this
  # checkout -- inside a git worktree that is the parent clone, where
  # this target does not exist.
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

  # Still nothing, and a single source file to work with. Looping the
  # twin only helps when a run does more work than starting a process
  # does; below that line every sample lands in the runtime coming up --
  # caml_init_domains, add_frame_descriptors, the dynamic linker -- and
  # none in the program. map_demo is the case: 200,000 runs gave 934k
  # samples, 207 of them in the twin's own binary, all of them startup.
  # The only way to reach that code is to loop inside one process, which
  # means wrapping the source, which is exactly what costs the generality
  # the pass above has. So it goes second, and only where it can work:
  # one file, whose text goes in verbatim under a line directive so the
  # symbols still point at the real program.
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
# The instrumentation picks its sink from VREPLAY_FILE, so the dump never
# mixes with the program's own output, which stays on the terminal.
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

# --- 5. hand the dump to the interface --------------------------------------
# Built with this repo's own toolchain, not the fork's -- deliberately no
# tc_env here. The dump's source paths are relative to the directory the
# compiler ran in, which is the project root in project mode and the
# scratch build context otherwise.
say "building the interface"
(cd "$interface" && dune build --root . app/bin/main.exe) ||
  die "interface build failed"
app_args=(-dump-file "$dump" -source-root "$source_root")
# -perf-file only if this interface has it. The flag arrives with the
# heat work; until the pinned interface carries it, passing it is an
# unknown-option error rather than a nicety.
if [ -f "$heat" ] &&
  "$interface/_build/default/app/bin/main.exe" -help 2>&1 |
  grep -q -- "-perf-file"; then
  app_args+=(-perf-file "$heat")
elif [ -f "$heat" ]; then
  say "note: this interface has no -perf-file; heat profile written but not shown"
fi
say "replaying in the TUI (q quits, arrows step)"
exec "$interface/_build/default/app/bin/main.exe" "${app_args[@]}"
