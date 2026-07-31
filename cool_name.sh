#!/usr/bin/env bash
# The outer shell of the visual replay debugger.
#
#   ./cool_name.sh path/to/program.ml
#
# Pipeline:
#   1. build the forked compiler if needed (bytecode world; redone
#      whenever the pinned submodule commit changes)
#   2. compile the program with -visual-replay, via a generated dune
#      project that uses the fork as its toolchain
#   3. run the instrumented bytecode -- replay events go to the dump
#      file via VREPLAY_FILE, the program's own output to the terminal
#   4. build the interface and replace this process with the TUI,
#      replaying the dump
#
# Artifacts land in _vreplay/<program-name>/ (gitignored).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compiler="$root/jsip-debugger-compiler"
interface="$root/jsip-debugger-interface"

say() { printf 'cool_name: %s\n' "$*"; }
die() {
  printf 'cool_name: error: %s\n' "$*" >&2
  exit 1
}

[ $# -eq 1 ] || die "usage: ./cool_name.sh path/to/program.ml"
prog="$1"
[ -f "$prog" ] || die "no such file: $prog"
case "$prog" in
*.ml) ;;
*) die "expected an .ml file, got: $prog" ;;
esac
[ -f "$compiler/configure" ] && [ -f "$interface/dune-project" ] ||
  die "submodules missing; run: git submodule update --init --recursive"

name="$(basename "${prog%.ml}")"
work="$root/_vreplay/$name"
dump="$work/$name.dump"
mkdir -p "$work"

# The scratch module keeps the program's own name when it is a valid
# module name (so the TUI's source pane shows e.g. map_demo.ml), and
# falls back to "main" otherwise.
case "$name" in
[a-z_]*[!a-zA-Z0-9_]* | [!a-z_]*) module=main ;;
*) module="$name" ;;
esac

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

cp "$prog" "$build/$module.ml"
cat >"$build/dune-project" <<'EOF'
(lang dune 3.0)
EOF
cat >"$build/dune" <<EOF
(executable
 (name $module)
 (modes byte)
 (flags (:standard -visual-replay -I $compiler/vreplay)))
EOF

PATH="$shims:$PATH" dune build --root "$build" --no-config "./$module.bc" ||
  die "instrumented build failed"

# --- 3. run it, dump going to its own sink ----------------------------------
# The instrumentation picks its sink from VREPLAY_FILE, so the dump never
# mixes with the program's own output, which stays on the terminal.
say "running $name (its output follows; replay events go to the dump)"
rm -f "$dump"
env -u CAML_LD_LIBRARY_PATH VREPLAY_FILE="$dump" \
  "$ocamlrun" "$build/_build/default/$module.bc" ||
  die "instrumented program exited nonzero"
[ -s "$dump" ] ||
  die "the run produced no replay events -- only calls involving stdlib \
Map/Set/Queue/Hashtbl are instrumented"
say "dump captured: ${dump#"$root/"} ($(grep -c '(event ' "$dump") events)"

# --- 4. hand the dump to the interface --------------------------------------
# Built with the normal opam toolchain. The dump's source paths are
# relative to the scratch project, so point -source-root there.
say "building the interface"
(cd "$interface" && dune build --root . app/bin/main.exe) ||
  die "interface build failed"
say "replaying in the TUI (q quits, arrows step)"
exec "$interface/_build/default/app/bin/main.exe" \
  -dump-file "$dump" \
  -source-root "$build/_build/default"
