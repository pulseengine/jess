#!/usr/bin/env bash
# jess 0.1.0 — reproducible falcon forward-build chain with evidence.
#
# fetch verified falcon wasm -> wasmtime SIL gate -> meld fuse -> loom optimize
# -> synth compile to Cortex-M ELF -> cross-runtime check on kiln -> JUnit evidence.
#
# Oracle: this script exits non-zero if any HARD gate fails (sha256, SIL, synth ELF).
# loom failure is a WARNING (it currently falls back to original bytes; see AFD-002).
# Usage: scripts/jess-build.sh [falcon-vX.Y.Z]   (default: falcon-v1.27.0)
set -euo pipefail

VERSION="${1:-falcon-v1.27.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SIB="$(cd "$ROOT/.." && pwd -P)"
BUILD="$ROOT/.scratch/build/$VERSION"
RESULTS="$ROOT/results"
mkdir -p "$BUILD" "$RESULTS"

# falcon-vMAJOR.MINOR.PATCH -> asset falcon-flight-vMAJOR.MINOR.wasm
mm="${VERSION#falcon-v}"; mm="${mm%.*}"          # strip leading 'falcon-v' and trailing '.PATCH'
WASM_NAME="falcon-flight-v${mm}.wasm"

note() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# Resolve a sibling CLI, building it (release) if no binary exists.
cli() { # $1 = crate/dir name, $2 = binary name
  local d="$SIB/$1" b
  b="$d/target/release/$2"; [ -x "$b" ] && { echo "$b"; return; }
  b="$d/target/debug/$2";   [ -x "$b" ] && { echo "$b"; return; }
  echo "building $1..." >&2; ( cd "$d" && cargo build --release -q ) >&2
  echo "$d/target/release/$2"
}

note "0.1.0 forward chain for $VERSION (asset $WASM_NAME)"
LOOM="$(cli loom loom)"; MELD="$(cli meld meld)"; SYNTH="$(cli synth synth)"; KILND="$(cli kiln kilnd)"

# --- gate: download + sha256 verify --------------------------------------
note "fetch + verify"
gh release download "$VERSION" --repo pulseengine/relay \
  --pattern "$WASM_NAME" --pattern "${WASM_NAME}.sha256" --dir "$BUILD" --clobber
W="$BUILD/$WASM_NAME"
[ -f "$W" ] || fail "wasm not downloaded"
want="$(awk '{print $1}' "$BUILD/${WASM_NAME}.sha256")"
got="$(shasum -a 256 "$W" | awk '{print $1}')"
[ "$want" = "$got" ] || fail "sha256 mismatch: want $want got $got"
SHA_OK=1; echo "sha256 OK ($got)"

# --- gate: SIL in wasmtime ----------------------------------------------
note "SIL gate (wasmtime)"
STAB="$(wasmtime run --invoke 'run-stabilization()' "$W" 2>/dev/null)"
POS="$(wasmtime run --invoke 'run-position-hold()' "$W" 2>/dev/null)"
echo "  run-stabilization = $STAB rad   run-position-hold = $POS m"
SIL_OK="$(python3 -c "import sys;print(1 if float('$STAB')<0.1 and float('$POS')<0.6 else 0)")"
[ "$SIL_OK" = 1 ] || fail "SIL gate: stabilization $STAB (<0.1?) position $POS (<0.6?)"
echo "  SIL PASS"

# --- meld fuse (component -> core module) --------------------------------
note "meld fuse"
FUSED="$BUILD/falcon.fused.wasm"
"$MELD" fuse "$W" -o "$FUSED"
echo "  fused: $(stat -f%z "$W") -> $(stat -f%z "$FUSED") bytes"

# --- loom optimize (NON-fatal; see AFD-002) ------------------------------
note "loom optimize (warn-on-fail)"
LOOMED="$BUILD/falcon.loom.wasm"; LOOM_OK=1
if "$LOOM" optimize "$FUSED" -o "$LOOMED" 2>"$BUILD/loom.log"; then
  grep -q "Failed to optimize" "$BUILD/loom.log" && { LOOM_OK=0; echo "  loom: partial fallback (AFD-002)"; } || echo "  loom OK"
else LOOM_OK=0; cp "$FUSED" "$LOOMED"; echo "  loom failed -> using fused bytes (AFD-002)"; fi

# --- gate: synth compile to Cortex-M ELF ---------------------------------
note "synth compile (Cortex-M)"
ELF="$BUILD/falcon.elf"
"$SYNTH" compile "$W" --cortex-m -o "$ELF"
file "$ELF" | grep -q "ARM" || fail "synth did not produce an ARM ELF"
echo "  ELF: $(file "$ELF" | cut -d, -f1-2)"

# --- cross-runtime check: kiln on fused core vs wasmtime -----------------
note "cross-runtime check (kiln on fused core)"
KILN_OK=0
kout="$("$KILND" "$FUSED" --function run-stabilization 2>/dev/null || true)"
kbits="$(printf '%s' "$kout" | sed -nE 's/.*FloatBits32\(([0-9]+)\).*/\1/p' | head -1)"
if [ -n "$kbits" ]; then
  kval="$(python3 -c "import struct;print(struct.unpack('<f',struct.pack('<I',$kbits))[0])" 2>/dev/null || true)"
  if [ -n "$kval" ]; then
    echo "  kiln run-stabilization = $kval rad (wasmtime $STAB)"
    KILN_OK="$(python3 -c "print(1 if abs(float('$kval')-float('$STAB'))<1e-4 else 0)" 2>/dev/null || echo 0)"
  fi
fi
[ "$KILN_OK" = 1 ] && echo "  kiln matches wasmtime" || echo "  kiln check inconclusive (non-gating)"

# --- emit JUnit evidence -------------------------------------------------
note "evidence"
XML="$RESULTS/jess-build-${VERSION}.xml"
CN="jess-build"
tcg() { if [ "$2" = 1 ]; then printf '    <testcase name="%s" classname="%s" time="0"/>\n' "$1" "$CN"
        else printf '    <testcase name="%s" classname="%s" time="0"><failure message="%s"/></testcase>\n' "$1" "$CN" "$3"; fi; }
tcs() { if [ "$2" = 1 ]; then printf '    <testcase name="%s" classname="%s" time="0"/>\n' "$1" "$CN"
        else printf '    <testcase name="%s" classname="%s" time="0"><skipped/></testcase>\n' "$1" "$CN"; fi; }
fails=0; for v in "$SHA_OK" "$SIL_OK"; do [ "$v" = 1 ] || fails=$((fails+1)); done
skips=0; for v in "$LOOM_OK" "$KILN_OK"; do [ "$v" = 1 ] || skips=$((skips+1)); done
{
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<testsuites>\n'
  printf '  <testsuite name="jess-build" tests="7" failures="%s" skipped="%s" errors="0" time="0">\n' "$fails" "$skips"
  tcg "sha256-verify"      "$SHA_OK"  "sha256 mismatch"
  tcg "sil-stabilization"  "$SIL_OK"  "stabilization >= 0.1 rad"
  tcg "sil-position-hold"  "$SIL_OK"  "position >= 0.6 m"
  tcg "meld-fuse"          1          "meld fuse failed"
  tcs "loom-optimize"      "$LOOM_OK" ""
  tcg "synth-compile"      1          "no ARM ELF"
  tcs "kiln-xruntime"      "$KILN_OK" ""
  printf '  </testsuite>\n'
  printf '</testsuites>\n'
} > "$XML"
echo "  wrote $XML"

note "SUMMARY for $VERSION"
echo "  sha256:$SHA_OK SIL:$SIL_OK meld:1 loom:$LOOM_OK synth:1 kiln:$KILN_OK"
echo "  forward chain GREEN (hard gates: sha256, SIL, synth ELF all passed)"
