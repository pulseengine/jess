#!/usr/bin/env bash
# Fused-core byte-reproducibility oracle (meld#325 resolved via `meld fuse --reproducible`).
#
# WHY: the FIRST-FLASH safety case needs the meld-fused falcon core to be a STABLE
# artifact — REQ-PIX-018 (scry/witness gate a re-verifiable input), sigil signing of
# the flashable image set, and deterministic replay (REQ-PIX-022) all assume that
# identical input -> identical fused bytes. meld#325 was that gap: default fusion
# embedded a random UUID attestation-id + wall-clock timestamp, so every run produced
# a different sha256. meld v0.38.0 added `--reproducible` (derive the id from content,
# take the timestamp from SOURCE_DATE_EPOCH); this oracle proves it holds on the real
# falcon core.
#
# ORACLE (exits non-zero on failure): two `--reproducible` fusions of the SAME input
# (same file at the SAME path) are byte-identical (same sha256). NEGATIVE CONTROL: two
# DEFAULT (no-flag) fusions differ — so the property comes from the flag, not from the
# input happening to be stable.
#
# KNOWN RESIDUAL (verified 2026-07-11, meld v0.39.0; filed upstream): `--reproducible`
# output still depends on the input file's PATH — identical bytes at two different paths
# fuse to DIFFERENT shas. So this oracle asserts the fixed-path guarantee (which is what a
# single CI runner needs for a stable gate) and additionally CHARACTERIZES the cross-path
# dependence as a diagnostic (reported, not asserted — it is an upstream gap, not a jess
# regression). A PORTABLE / cross-machine attestation sha needs the upstream path-independence
# fix; until then the safety-case gate keys on scry invariants (TEST-PIX-022), not the sha.
#
# Usage: tools/repro/fuse-repro-oracle.sh [falcon-vX.Y.Z | /path/to/component.wasm]
#   default: a pinned falcon component (fetched via gh) — same input class as the scry gate.
# Tools: MELD (env or sibling build ../meld/target/release/meld or `meld` on PATH); needs meld >= v0.38.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
ARG="${1:-falcon-v1.112.0}"
fail() { echo "REPRO ORACLE FAIL: $*" >&2; exit 1; }

# --- resolve meld (>= v0.38 for --reproducible) --------------------------
resolve_meld() {
  [ -n "${MELD:-}" ] && { echo "$MELD"; return; }
  command -v meld >/dev/null 2>&1 && { echo meld; return; }
  local b="$ROOT/../meld/target/release/meld"; [ -x "$b" ] && { echo "$b"; return; }
  fail "no meld (set MELD=, put meld on PATH, or build ../meld) — needs >= v0.38 for --reproducible"
}
MELD="$(resolve_meld)"
"$MELD" fuse --help 2>&1 | grep -q -- '--reproducible' || fail "this meld lacks --reproducible (need >= v0.38): $("$MELD" --version 2>&1)"

# --- acquire an input component ------------------------------------------
if [[ "$ARG" == *.wasm ]]; then
  [ -f "$ARG" ] || fail "no such wasm: $ARG"; COMP="$ARG"
else
  mm="${ARG#falcon-v}"; mm="${mm%.*}"; COMP="$WORK/falcon-flight-v${mm}.wasm"
  gh release download --repo pulseengine/relay "$ARG" -p "falcon-flight-v${mm}.wasm" \
     --clobber --dir "$WORK" >/dev/null 2>&1 || fail "could not fetch $ARG component"
fi
echo "meld:  $("$MELD" --version 2>&1 | head -1)"
echo "input: $COMP ($(wc -c <"$COMP") bytes)"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# --- reproducible x2 (MUST match) ----------------------------------------
"$MELD" fuse "$COMP" -o "$WORK/rep1.wasm" --reproducible >/dev/null 2>&1 || fail "reproducible fuse #1 errored"
"$MELD" fuse "$COMP" -o "$WORK/rep2.wasm" --reproducible >/dev/null 2>&1 || fail "reproducible fuse #2 errored"
R1="$(sha "$WORK/rep1.wasm")"; R2="$(sha "$WORK/rep2.wasm")"
echo "--reproducible: $R1"
[ "$R1" = "$R2" ] || fail "two --reproducible fusions DIFFER ($R1 != $R2) — meld#325 not held"

# --- negative control: default x2 (SHOULD differ) ------------------------
"$MELD" fuse "$COMP" -o "$WORK/def1.wasm" >/dev/null 2>&1
"$MELD" fuse "$COMP" -o "$WORK/def2.wasm" >/dev/null 2>&1
D1="$(sha "$WORK/def1.wasm")"; D2="$(sha "$WORK/def2.wasm")"
if [ "$D1" = "$D2" ]; then
  echo "note: default (no-flag) fusion was ALSO stable this run — negative control inconclusive (not a failure)"
else
  echo "negative control OK: default fusion differs run-to-run ($D1 != $D2)"
fi

# --- cross-path PATH-INDEPENDENCE (ASSERTED — meld#341 fixed in meld v0.41.3) --------
# Identical CONTENT at two different paths must fuse to the IDENTICAL sha, so the fused
# artifact is a PORTABLE attestation key (not just stable for one fixed path). This was a
# diagnostic while meld#341 was open; it is now a hard assertion. If it regresses (or the
# meld in use predates the fix), the gate fails loudly rather than silently under-checking.
CPA="$WORK/pa/in.wasm"; CPB="$WORK/pb/in.wasm"; mkdir -p "$WORK/pa" "$WORK/pb"
cp "$COMP" "$CPA"; cp "$COMP" "$CPB"
"$MELD" fuse "$CPA" -o "$WORK/cpa.wasm" --reproducible >/dev/null 2>&1 || fail "cross-path fuse #1 errored"
"$MELD" fuse "$CPB" -o "$WORK/cpb.wasm" --reproducible >/dev/null 2>&1 || fail "cross-path fuse #2 errored"
CPA_SHA="$(sha "$WORK/cpa.wasm")"; CPB_SHA="$(sha "$WORK/cpb.wasm")"
[ "$CPA_SHA" = "$CPB_SHA" ] || fail "PATH-DEPENDENT: identical bytes at 2 paths fuse to different sha ($CPA_SHA != $CPB_SHA) — meld#341 regressed, or this meld predates v0.41.3"
echo "cross-path: PATH-INDEPENDENT (asserted) — identical bytes at different paths fuse identically ($CPA_SHA)"

echo "REPRO OK — meld#325 + meld#341 resolved: --reproducible is byte-stable AND path-independent (portable attestation key $R1)."
