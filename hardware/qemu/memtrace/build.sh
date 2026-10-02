#!/usr/bin/env bash
# Build the memtrace TCG plugin against the INSTALLED qemu's plugin header.
#
# QEMU 11.1.1 accepts `-plugin` and ships none, so this is the whole supply. The header is
# versioned with the emulator (QEMU_PLUGIN_VERSION, currently 7) and the API is NOT stable
# across versions — v7 changed the translate callback to take a userdata argument and made the
# atexit callback `void(*)(void*)`. So this does not vendor the header; it compiles against the
# one belonging to the qemu that will load the result, and FAILS if they disagree. A plugin built
# against a different version loads and then misbehaves, which is worse than not loading.
set -uo pipefail
cd "$(dirname "$0")"
CC="${CC:-clang}"
OUT="${OUT:-libmemtrace.dylib}"
[ "$(uname -s)" = "Linux" ] && OUT="${OUT%.dylib}.so"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
skip() { printf 'SKIP: %s\n' "$*" >&2; exit 2; }

# Find qemu-plugin.h and glib. pkg-config is NOT assumed — it is absent on this Mac even though
# glib is installed, and a build that needs it would be unbuildable here for no reason.
HDR=""
for d in "${QEMU_PLUGIN_INCLUDE:-}" /opt/homebrew/include /usr/local/include /usr/include; do
  [ -n "$d" ] && [ -f "$d/qemu-plugin.h" ] && { HDR="$d"; break; }
done
[ -n "$HDR" ] || skip "no qemu-plugin.h found. It ships with qemu's headers; set
   QEMU_PLUGIN_INCLUDE=<dir containing qemu-plugin.h>. Without it this is 'could not build',
   not 'the tracer is broken'."

GI=""
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists glib-2.0 2>/dev/null; then
  GI="$(pkg-config --cflags glib-2.0)"
  GL="$(pkg-config --libs glib-2.0)"
else
  for g in "${GLIB_PREFIX:-}" /opt/homebrew/opt/glib /usr/local/opt/glib /usr; do
    [ -n "$g" ] && [ -f "$g/include/glib-2.0/glib.h" ] && {
      GI="-I$g/include/glib-2.0 -I$g/lib/glib-2.0/include"; GL="-L$g/lib -lglib-2.0"; break; }
  done
fi
[ -n "$GI" ] || skip "glib headers not found (qemu-plugin.h includes <glib.h>). Set GLIB_PREFIX."

V="$(grep -oE '#define QEMU_PLUGIN_VERSION [0-9]+' "$HDR/qemu-plugin.h" | awk '{print $3}')"
echo "   qemu-plugin.h: $HDR (API version ${V:-unknown})"

# -undefined dynamic_lookup on darwin: the qemu_plugin_* symbols are resolved by the loading
# emulator, not present at link time.
LDEXTRA=""
[ "$(uname -s)" = "Darwin" ] && LDEXTRA="-undefined dynamic_lookup"

# shellcheck disable=SC2086
$CC -O2 -shared -fPIC -o "$OUT" memtrace.c -I"$HDR" $GI $GL $LDEXTRA || fail "compile failed"
[ -s "$OUT" ] || fail "no output produced"
echo "   built $OUT ($(wc -c < "$OUT") bytes)"

# THE BUILD IS NOT THE TEST. A plugin that compiles and then records nothing is the exact
# failure mode this whole instrument exists to avoid, so prove it LOADS and SEES accesses before
# calling it built. Needs an image; skipped rather than faked if there is none.
E="${E:-../../../.scratch/invoke/ekf.elf}"
if command -v qemu-system-arm >/dev/null 2>&1 && [ -f "$E" ]; then
  T="$(mktemp)"
  { sleep 6; echo quit; } | qemu-system-arm -machine mps2-an500 -cpu cortex-m7 -display none \
      -serial none -monitor stdio -kernel "$E" \
      -plugin "$(pwd)/$OUT,out=$T,lo=20000000,hi=20012000" >/dev/null 2>&1
  SEEN="$(grep -oE 'seen=[0-9]+' "$T" 2>/dev/null | head -1 | cut -d= -f2)"
  rm -f "$T"
  [ -n "${SEEN:-}" ] && [ "${SEEN:-0}" -gt 0 ] \
    || fail "the plugin loaded but reported seen=${SEEN:-<no trailer>} accesses. A tracer that
   sees nothing produces an empty trace, and an empty trace's 'no findings' says nothing.
   Refusing to report a successful build."
  echo "   smoke: the plugin loaded and observed $SEEN accesses"
else
  echo "   smoke: SKIPPED (need qemu-system-arm and $E) — built but not shown to observe anything"
fi
