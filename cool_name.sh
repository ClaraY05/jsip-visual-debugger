#!/usr/bin/env bash
# The outer shell of the visual replay debugger.
#
#   ./cool_name.sh path/to/program.ml
#
# Pipeline:
#   1. build the forked compiler if it isn't built yet (bytecode world)
#   2. compile the program with -visual-replay, via a generated dune
#      project that uses the fork as its toolchain
#   3. run the instrumented bytecode and capture the replay dump
#   4. build the interface and hand it the dump
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

cp "$prog" "$build/main.ml"
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
# The instrumentation writes the replay events to stdout, so the dump is
# the program's captured stdout (its own prints included, for now); the
# program's stderr passes through.
say "running $name and capturing the replay dump"
env -u CAML_LD_LIBRARY_PATH "$ocamlrun" "$build/_build/default/main.bc" \
  >"$dump" ||
  die "instrumented program exited nonzero; partial dump in $dump"
say "dump captured: ${dump#"$root/"} ($(wc -l <"$dump") lines)"

# --- 4. hand the dump to the interface --------------------------------------
# Built with the normal opam toolchain. Release profile: the interface's
# current tip has warnings that the dev profile would turn into errors.
say "building the interface"
(cd "$interface" && dune build --root . --profile release app/bin/main.exe) ||
  die "interface build failed"
say "launching the interface on the dump"
"$interface/_build/default/app/bin/main.exe" "$dump"
say "done"
