#!/usr/bin/env bash
# jess scry sound-analysis gate (REQ-PIX-018 leg b / TEST-PIX-022).
#
# The DO-333 sound-static-analysis leg of the V, on the CONSUMED (released,
# stripped) falcon wasm: fetch a pinned falcon component -> meld fuse to a Core
# module -> run scry's sound abstract interpretation (scry-sai-core) -> assert
# the analysis COMPLETES and never silently drops to an unsound ⊤ fallback.
# Complements relay's source-level DWARF MC/DC (which jess cannot run on the
# stripped release); see the deviation recorded at hub pulseengine.eu#98.
#
# Oracle (exits non-zero on any):
#   1. scry-run exits non-zero        (scry could not soundly analyze the core)
#   2. call_edges_unsound_fallback>0  (a call site lost soundness)
#   3. diag_unsound_fallback>0        (any unsoundness-fallback diagnostic)
# The full JSON verdict is printed as evidence (and appended to the CI summary).
#
# Usage: tools/scry-gate/run.sh [falcon-vX.Y.Z | /path/to/fused-core.wasm]
set -euo pipefail

FALCON_PIN="falcon-v1.112.0"     # pinned for reproducibility (bump deliberately)
ARG="${1:-$FALCON_PIN}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SIB="$(cd "$ROOT/.." && pwd -P)"
WORK="$ROOT/tools/scry-gate/.work"
mkdir -p "$WORK"

note() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
fail() { printf '\033[31mGATE FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# --- resolve meld (sibling build or pinned release) ----------------------
resolve_meld() {
  command -v meld >/dev/null 2>&1 && { echo meld; return; }
  local b="$SIB/meld/target/release/meld"
  [ -x "$b" ] && { echo "$b"; return; }
  fail "no meld on PATH and no sibling build ($b) — CI fetches the pinned release"
}
MELD="$(resolve_meld)"

# --- acquire the fused Core module ---------------------------------------
if [[ "$ARG" == *.wasm ]]; then
  [ -f "$ARG" ] || fail "no such wasm: $ARG"
  FUSED="$ARG"
  note "using local fused core: $FUSED"
else
  mm="${ARG#falcon-v}"; mm="${mm%.*}"
  COMP="$WORK/falcon-flight-v${mm}.wasm"
  note "fetch $ARG component (asset falcon-flight-v${mm}.wasm)"
  gh release download --repo pulseengine/relay "$ARG" \
     -p "falcon-flight-v${mm}.wasm" --clobber --dir "$WORK" \
     || fail "could not download $ARG"
  echo "  sha256: $(shasum -a 256 "$COMP" | awk '{print $1}')"
  FUSED="$WORK/falcon.fused.wasm"
  note "meld fuse (component -> Core module)"
  "$MELD" fuse "$COMP" -o "$FUSED" >/dev/null
  echo "  fused: $(wc -c <"$COMP") -> $(wc -c <"$FUSED") bytes"
fi

# --- run scry ------------------------------------------------------------
note "scry sound abstract interpretation"
( cd "$ROOT/tools/scry-gate/scry-run" && cargo build --release -q )
VERDICT="$WORK/verdict.json"
"$ROOT/tools/scry-gate/scry-run/target/release/scry-run" "$FUSED" >"$VERDICT"
cat "$VERDICT"

# --- assert the gate invariants ------------------------------------------
jqget() { grep -oE "\"$1\": [0-9-]+" "$VERDICT" | grep -oE '[0-9-]+$'; }
edges_unsound="$(jqget call_edges_unsound_fallback)"
diag_unsound="$(jqget diag_unsound_fallback)"
[ "${edges_unsound:-1}" = "0" ] || fail "call_edges_unsound_fallback=$edges_unsound (scry lost soundness at a call site)"
[ "${diag_unsound:-1}" = "0" ]  || fail "diag_unsound_fallback=$diag_unsound (unsoundness-fallback diagnostic present)"

note "GATE PASS — scry soundly analyzed the fused falcon core (0 unsound-fallback)"
