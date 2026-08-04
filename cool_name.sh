#!/usr/bin/env bash
# The outer shell of the visual replay debugger.
#
#   ./cool_name.sh path/to/program.ml        # single file
#   ./cool_name.sh path/to/program-dir/      # multi-file: needs a main.ml
#
# Pipeline:
#   1. build the forked compiler if it isn't built yet (bytecode world)
#   2. compile the program with -visual-replay, via a generated dune
#      project that uses the fork as its toolchain
#   3. run the instrumented bytecode and capture the replay dump
#   3b. perf-sample the *unchanged* program, natively compiled, and
#       distill a per-function compute profile (heat.sexp)
#   4. build the interface and hand it the dump (and the heat profile)
#
# Artifacts land in _vreplay/<program-name>/ (gitignored).
#
# COMPILER_DIR / INTERFACE_DIR override the submodule checkouts, e.g. to
# run against standalone clones that are ahead of the pinned commits.
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

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compiler="${COMPILER_DIR:-$root/jsip-debugger-compiler}"
interface="${INTERFACE_DIR:-$root/jsip-debugger-interface}"

say() { printf 'cool_name: %s\n' "$*"; }
die() {
  printf 'cool_name: error: %s\n' "$*" >&2
  exit 1
}

[ $# -eq 1 ] || die "usage: ./cool_name.sh path/to/program.ml | path/to/dir"
prog="${1%/}"
# A directory is a multi-file program; its entry point must be main.ml
# (the other modules are ordinary dependencies dune sorts out).
if [ -d "$prog" ]; then
  [ -f "$prog/main.ml" ] ||
    die "a multi-file program needs a main.ml: $prog"
  name="$(basename "$prog")"
  main_src="$prog/main.ml"
else
  [ -f "$prog" ] || die "no such file: $prog"
  case "$prog" in
  *.ml) ;;
  *) die "expected an .ml file or a directory, got: $prog" ;;
  esac
  name="$(basename "${prog%.ml}")"
  main_src="$prog"
fi
[ -f "$compiler/configure" ] && [ -f "$interface/dune-project" ] ||
  die "submodules missing; run: git submodule update --init --recursive"

[ $# -ge 1 ] ||
  die "usage: ./cool_name.sh path/to/program.ml [args...]
             ./cool_name.sh path/to/target.exe [args...]"
prog="$1"
shift
prog_args=("$@")
# Either an .ml file to instrument, or the dune target to build -- the
# second is the one to reach for in a project that already has a `dune`
# saying what its executable is called.
case "$prog" in
*.ml)
  [ -f "$prog" ] || die "no such file: $prog"
  ;;
*.exe)
  [ -d "$(dirname "$prog")" ] || die "no such directory: $(dirname "$prog")"
  ;;
*) die "expected an .ml file or a dune .exe target, got: $prog" ;;
esac
prog="$(cd "$(dirname "$prog")" && pwd)/$(basename "$prog")"
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

want_rev="$(git -C "$compiler" rev-parse HEAD)"
built_rev="$(cat "$prefix/.built-rev" 2>/dev/null || true)"

if [ "$built_rev" != "$want_rev" ] || ! [ -f "$compiler/vreplay/vreplay.cma" ]; then
  say "building the forked compiler at ${want_rev:0:12} (~10 min from scratch)"
  # `make install` is expected to die partway: on a bytecode-only tree it
  # aborts at tools/ocamldep.opt, after everything we need (runtime,
  # stdlib, byte binaries) is already in place. Tolerate it, hand-finish
  # the names it never got to, and verify the pieces that matter.
  (cd "$compiler" &&
    { [ -f Makefile.config ] || ./configure -C --prefix "$compiler/_install"; } &&
    make -j"$(nproc)" world &&
    testing/run_tests.sh map_basic &&
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
  cp -p "$compiler"/vreplay/*.cmi "$compiler"/vreplay/*.cma "$ocamllib/vreplay/"

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

if [ -d "$prog" ]; then
  cp "$prog"/*.ml "$build/"
  cp "$prog"/*.mli "$build/" 2>/dev/null || true
else
  cp "$prog" "$build/main.ml"
fi
cat >"$build/dune-project" <<'EOF'
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
  # Standalone mode. The scratch module keeps the program's own name when
  # it is a valid module name (so the TUI's source pane shows e.g.
  # map_demo.ml), and falls back to "main" otherwise.
  case "$name" in
  [a-z_]*[!a-zA-Z0-9_]* | [!a-z_]*) module=main ;;
  *) module="$name" ;;
  esac

  # Libraries the file opens. Anything Jane Street here is ppx_jane
  # territory too: the deriving attributes are common enough in such
  # programs that leaving the driver out is the surprising choice.
  libs=""
  for lib in base core core_unix async; do
    case "$lib" in
    core_unix) mod=Core_unix ;;
    *) mod="$(printf '%s' "$lib" | sed 's/^./\U&/')" ;;
    esac
    grep -qE "^[[:space:]]*open!?[[:space:]]+$mod\b" "$prog" &&
      libs="$libs $lib"
  done

  say "compiling $prog with -visual-replay (scratch project${libs:+, linking$libs})"
  cp "$prog" "$builddir/$module.ml"
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
if [ -n "${VREPLAY_DUMP_ONLY:-}" ]; then
  say "VREPLAY_DUMP_ONLY set; stopping before the TUI. Replay it with:"
  say "  $interface/_build/default/app/bin/main.exe \\"
  say "    -dump-file $dump -source-root $source_root"
  exit 0
fi

PATH="$shims:$PATH" dune build --root "$build" --no-config ./main.bc ||
  die "instrumented build failed"

# --- 3. run it, capture the dump --------------------------------------------
# Newer fork branches write the replay events to the VREPLAY_FILE sink;
# older ones print them to stdout. Ask for the sink, and if the runtime
# ignored it, fall back to the captured stdout (the old behavior, replay
# events interleaved with the program's own prints).
say "running $name and capturing the replay dump"
rm -f "$dump"
env -u CAML_LD_LIBRARY_PATH VREPLAY_FILE="$dump" \
  "$ocamlrun" "$build/_build/default/main.bc" >"$work/stdout.txt" ||
  die "instrumented program exited nonzero; partial dump in $work"
[ -s "$dump" ] || mv "$work/stdout.txt" "$dump"
say "dump captured: ${dump#"$root/"} ($(wc -l <"$dump") lines)"

# --- 3b. perf heat capture (optional) ---------------------------------------
# Samples the *unchanged* program -- its text is byte-identical; only the
# generated harness around it loops it in-process, so a microsecond-scale
# program accumulates enough samples -- natively compiled with the opam
# switch's ocamlopt, then distills the report into the per-function
# profile (heat.sexp) the interface colors its call stack with. Skipped
# with a warning when perf or the native switch is missing: heat is
# optional, the debugger runs without it.
heat="$work/heat.sexp"
rm -f "$heat"
heat_switch="${JSIP_HEAT_SWITCH:-5.2.0+ox}"
# The wrapped entry module: for a single file it keeps the program's own
# basename (so symbol module paths match the real program); a multi-file
# program's entry is its main.ml. Only the entry is looped — dependency
# modules are definitions and evaluate once.
if [ -d "$prog" ]; then wrap_name="main"; else wrap_name="$name"; fi
module_name="${wrap_name^}"

if ! command -v perf >/dev/null 2>&1; then
  say "perf not found; skipping heat capture"
elif ! opam exec --switch "$heat_switch" -- ocamlopt -version \
  >/dev/null 2>&1; then
  say "opam switch $heat_switch has no ocamlopt; skipping heat capture"
else
  say "capturing perf heat profile (native build, looped in-process)"
  perfdir="$work/perf"
  rm -rf "$perfdir"
  mkdir -p "$perfdir/build"
  if [ -d "$prog" ]; then
    for src in "$prog"/*.ml; do
      [ "$(basename "$src")" = "main.ml" ] || cp "$src" "$perfdir/build/"
    done
    cp "$prog"/*.mli "$perfdir/build/" 2>/dev/null || true
  fi
  wrapped="$perfdir/build/$wrap_name.ml"
  {
    printf 'let () =\n'
    printf '  let n = int_of_string (Sys.getenv "JSIP_HEAT_ITERS") in\n'
    printf '  for _ = 1 to n do\n'
    printf '    let module _ = struct\n'
    printf '# 1 "%s.ml"\n' "$wrap_name"
    cat "$main_src"
    printf '    end in ()\n'
    printf '  done\n'
  } >"$wrapped"
  # a scratch dune project, so multi-file programs get their modules
  # compiled in dependency order without us sorting them
  cat >"$perfdir/build/dune-project" <<'EOF'
(lang dune 3.0)
EOF
  cat >"$perfdir/build/dune" <<EOF
(executable
 (name $wrap_name)
 (modes native))
EOF
  if ! opam exec --switch "$heat_switch" -- dune build \
    --root "$perfdir/build" --no-config "./$wrap_name.exe" \
    >"$perfdir/build.log" 2>&1; then
    say "native build for perf failed (see ${perfdir#"$root/"}/build.log); skipping heat capture"
  else
    exe="$perfdir/build/_build/default/$wrap_name.exe"
    # aim for ~3s of looped wall time so `perf record -F max` collects
    # a few hundred thousand samples whatever the program's size
    calib_iters=10000
    start_ms=$(date +%s%3N)
    JSIP_HEAT_ITERS=$calib_iters "$exe" >/dev/null 2>&1 || true
    elapsed_ms=$(($(date +%s%3N) - start_ms))
    [ "$elapsed_ms" -lt 1 ] && elapsed_ms=1
    iters=$((calib_iters * 3000 / elapsed_ms))
    [ "$iters" -lt 10000 ] && iters=10000
    [ "$iters" -gt 50000000 ] && iters=50000000
    (cd "$root" && dune build bin/perf_heat_interface.exe) ||
      die "perf_heat_interface build failed"
    for attempt in 1 2; do
      if ! perf record -F max -o "$perfdir/perf.data" -- \
        env JSIP_HEAT_ITERS="$iters" "$exe" \
        >/dev/null 2>"$perfdir/perf.log"; then
        say "perf record failed (see ${perfdir#"$root/"}/perf.log); skipping heat capture"
        break
      fi
      status=0
      perf report -i "$perfdir/perf.data" --stdio --dsos "$wrap_name.exe" \
        --percent-limit 0 -F sample,sym 2>/dev/null |
        "$root/_build/default/bin/perf_heat_interface.exe" "$module_name" "$heat" ||
        status=$?
      if [ "$status" -eq 0 ]; then
        say "heat profile: ${heat#"$root/"}"
        break
      elif [ "$status" -eq 3 ] && [ "$attempt" -eq 1 ]; then
        iters=$((iters * 10))
        [ "$iters" -gt 50000000 ] && iters=50000000
        say "too few samples; retrying with $iters iterations"
      else
        say "heat capture failed (status $status); continuing without heat"
        break
      fi
    done
  fi
fi

# --- 4. hand the dump to the interface --------------------------------------
# Built with the normal opam toolchain. Release profile: the interface's
# current tip has warnings that the dev profile would turn into errors.
# --- 5. hand the dump to the interface --------------------------------------
# Built with this repo's own toolchain, not the fork's -- deliberately no
# tc_env here. The dump's source paths are relative to the directory the
# compiler ran in, which is the project root in project mode and the
# scratch build context otherwise.
say "building the interface"
(cd "$interface" && dune build --root . app/bin/main.exe) ||
  die "interface build failed"
say "launching the interface on the dump"
app_args=(-dump-file "$dump" -source-root "$build")
[ -f "$heat" ] && app_args+=(-perf-file "$heat")
"$interface/_build/default/app/bin/main.exe" "${app_args[@]}"
say "done"
say "replaying in the TUI (q quits, arrows step)"
exec "$interface/_build/default/app/bin/main.exe" \
  -dump-file "$dump" \
  -source-root "$source_root"
