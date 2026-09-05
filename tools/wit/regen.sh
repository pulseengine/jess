#!/usr/bin/env bash
# Regenerate the inter-core WIT contracts FROM the AADL via spar (REQ-PIX-007,
# feature-loop step 2: WIT is DERIVED from spar, never hand-written). Then assert
# the committed wit/ matches — a hand-edit or an un-regenerated AADL change fails
# the gate. spar codegen is deterministic (byte-identical regen), so this is exact.
#
# Usage: tools/wit/regen.sh [--check]   (--check = CI mode: regen to temp + diff, no write)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
AADL="$ROOT/hardware/pixhawk6x-rt.aadl"
ROOTSYS="Pixhawk6XRT::Pixhawk6XRT.v2a"
# Resolve spar through varve by default, NOT bare PATH.
#
# This used to be `SPAR="${SPAR:-spar}"`. On a machine with a stale cargo-installed spar ahead
# of the shims, that silently selects a DIFFERENT tool than the pinned one and fails with
# `Unknown command: codegen` — an error that names the subcommand rather than the binary, so it
# reads like the script is wrong. Measured here: PATH spar = ~/.cargo/bin/spar (no codegen,
# exit 1); varve-pinned spar 0.40.0 = WIT-DERIVATION OK, exit 0. Same script, same model, two
# answers, decided by $PATH.
#
# Same shape as the MELD/LOOM overrides in tools/appcompose and hardware/renode/cascade-invoke:
# an explicit SPAR= still wins (CI supplies its own pinned binary), varve is the default, and
# bare PATH is the last resort rather than the first.
if [ -n "${SPAR:-}" ]; then
  :
elif command -v varve >/dev/null 2>&1 && varve which spar >/dev/null 2>&1; then
  SPAR="$(varve which spar | grep -oE '/[^ ]*spar' | head -1)"
else
  SPAR="spar"
fi

if [ "${1:-}" = "--check" ]; then
  tmp="$(mktemp -d)"
  "$SPAR" codegen --root "$ROOTSYS" --format wit --output "$tmp" "$AADL" >/dev/null
  if diff -rq "$tmp/wit" "$ROOT/wit" >/dev/null 2>&1; then
    echo "WIT-DERIVATION OK — committed wit/ matches spar codegen from the AADL"
  else
    echo "WIT-DERIVATION DRIFT — wit/ is stale or hand-edited; run tools/wit/regen.sh" >&2
    diff -r "$ROOT/wit" "$tmp/wit" >&2 || true
    exit 1
  fi
else
  "$SPAR" codegen --root "$ROOTSYS" --format wit --output "$ROOT" "$AADL"
  echo "regenerated wit/ from $AADL"
fi
