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

work="$root/_vreplay/$name"
dump="$work/dump.txt"
mkdir -p "$work"

# --- 1. the forked compiler -------------------------------------------------
# Bytecode only: native has never built on the vreplay branch, so it's
# `make world`, not `world.opt`. The fork is configured and installed to
# its own _install prefix -- the layout the fork's team uses -- so that
# tools (dune especially) see an installed-shaped lib dir. The installed
# runtime is also what provides the caml_wire_emit primitive.
prefix="$compiler/_install"
ocamlrun="$prefix/bin/ocamlrun"

if ! { [ -f "$prefix/bin/ocamlc" ] && [ -f "$ocamlrun" ] &&
  [ -f "$compiler/vreplay/vreplay.cma" ]; }; then
  say "forked compiler not built yet; building it (one-time, ~10 min)"
  # `make install` is expected to die partway: on a bytecode-only tree it
  # aborts at tools/ocamldep.opt, after everything we need (runtime,
  # stdlib, byte binaries) is already in place. Tolerate it, hand-finish
  # the names it never got to, and verify the pieces that matter.
  (cd "$compiler" &&
    { [ -f Makefile.config ] || ./configure -C --prefix "$compiler/_install"; } &&
    make -j"$(nproc)" world &&
    { make install || true; } &&
    ln -sf ocamlc.byte _install/bin/ocamlc &&
    ln -sf ocamldep.byte _install/bin/ocamldep &&
    cp -p Makefile.config _install/lib/ocaml/Makefile.config &&
    [ -f _install/bin/ocamlrun ] &&
    [ -f _install/lib/ocaml/stdlib.cma ] &&
    [ -f _install/lib/ocaml/runtime-launch-info ]) \
    >"$root/_vreplay/compiler-build.log" 2>&1 ||
    die "compiler build failed; see _vreplay/compiler-build.log"
fi

# --- 2. compile with -visual-replay via dune --------------------------------
# A scratch dune project wraps the user's file, and shim scripts put the
# fork's ocamlc/ocamldep on PATH (each runs through the fork's runtime,
# sidestepping shebang length limits). The explicit -I makes vreplay.cma
# resolvable from where the fork's Makefile builds it; the library is not
# installed into the prefix.
say "compiling $prog with -visual-replay (dune, forked toolchain)"
build="$work/build"
shims="$work/shims"
rm -rf "$build" "$shims"
mkdir -p "$build" "$shims"

for tool in ocamlc ocamldep; do
  cat >"$shims/$tool" <<EOF
#!/bin/sh
exec "$ocamlrun" "$prefix/bin/$tool" "\$@"
EOF
  chmod +x "$shims/$tool"
done

if [ -d "$prog" ]; then
  cp "$prog"/*.ml "$build/"
  cp "$prog"/*.mli "$build/" 2>/dev/null || true
else
  cp "$prog" "$build/main.ml"
fi
cat >"$build/dune-project" <<'EOF'
(lang dune 3.0)
EOF
cat >"$build/dune" <<EOF
(executable
 (name main)
 (modes byte)
 (flags (:standard -visual-replay -I $compiler/vreplay)))
EOF

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
say "building the interface"
(cd "$interface" && dune build --root . --profile release app/bin/main.exe) ||
  die "interface build failed"
say "launching the interface on the dump"
app_args=(-dump-file "$dump" -source-root "$build")
[ -f "$heat" ] && app_args+=(-perf-file "$heat")
"$interface/_build/default/app/bin/main.exe" "${app_args[@]}"
say "done"
