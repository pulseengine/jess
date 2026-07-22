#!/usr/bin/env bash
# jess sigil attestation gate (DD-023 / REQ-PIX-021 terminal rung).
#
# Proves the meld-fused falcon core can be SIGNED + VERIFIED with sigil (wsc) — the
# "sigil-signed flashable set" step of FIRST-FLASH. Fetches a pinned falcon component
# -> meld fuse --reproducible (a PATH-INDEPENDENT digest, meld#341) -> sigil-run drives
# sigil's wsc-component.wasm (wasm-signatures:wasmsign/signing) to keygen -> sign ->
# verify==true, and a NEGATIVE CONTROL: a 1-byte-tampered core must verify==false.
#
# Usage: tools/sigil-gate/run.sh [falcon-vX.Y.Z | /path/to/fused-or-component.wasm]
# Tools: MELD (env/PATH/sibling; >= v0.41.3 for path-independence), cargo (builds sigil-run).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
D="$ROOT/tools/sigil-gate"
WORK="$(mktemp -d)"
ARG="${1:-falcon-v1.127.0}"
note() { printf '\033[1m== %s ==\033[0m\n' "$*"; }
fail() { echo "SIGIL GATE FAIL: $*" >&2; exit 1; }

resolve_meld() {
  [ -n "${MELD:-}" ] && { echo "$MELD"; return; }
  command -v meld >/dev/null 2>&1 && { echo meld; return; }
  local b="$ROOT/../meld/target/release/meld"; [ -x "$b" ] && { echo "$b"; return; }
  fail "no meld (set MELD=, PATH, or ../meld) — need >= v0.41.3"
}
MELD="$(resolve_meld)"
[ -f "$D/wsc-component.wasm" ] || fail "missing $D/wsc-component.wasm (sigil signer component)"

# --- acquire the module to sign (fused Core, or a given wasm) --------------
if [[ "$ARG" == *.wasm ]]; then
  [ -f "$ARG" ] || fail "no such wasm: $ARG"
  # if it's a component, fuse it; if already a core module, sign as-is
  if wasm-tools component wit "$ARG" >/dev/null 2>&1; then
    note "meld fuse (component -> Core, --reproducible)"; "$MELD" fuse "$ARG" -o "$WORK/fused.wasm" --reproducible >/dev/null
    MOD="$WORK/fused.wasm"
  else MOD="$ARG"; fi
else
  mm="${ARG#falcon-v}"; mm="${mm%.*}"
  note "fetch $ARG component (asset falcon-flight-v${mm}.wasm)"
  gh release download --repo pulseengine/relay "$ARG" -p "falcon-flight-v${mm}.wasm" --clobber --dir "$WORK" \
     || fail "could not download $ARG"
  note "meld fuse --reproducible (path-independent digest, meld#341)"
  "$MELD" fuse "$WORK/falcon-flight-v${mm}.wasm" -o "$WORK/fused.wasm" --reproducible >/dev/null
  MOD="$WORK/fused.wasm"
fi
echo "  module: $(wc -c <"$MOD") bytes (sha $(shasum -a 256 "$MOD" | awk '{print $1}'))"

# --- build + run the sigil-run host driver --------------------------------
note "build sigil-run (wasmtime component host over sigil's signing interface)"
( cd "$D/sigil-run" && cargo build --release -q )
note "sigil keygen -> sign -> verify (+ tamper negative control)"
"$D/sigil-run/target/release/sigil-run" "$D/wsc-component.wasm" "$MOD"
