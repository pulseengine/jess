#!/usr/bin/env bash
# Hardware-free simulation of the gust failsafe node (the F100/IO-MCU role) in
# wasmtime — the SIL rung of the two-track ladder (wasmtime ‖ Renode ‖ silicon).
# Runs the SAME wasm the eval board runs (gale benches/gust/wasm-kernel), with zero
# hardware and zero Renode wall-clock. Oracle: gust_mix(1024) == 1500 — REFLASH.md's
# silicon kill-criterion, checked here in software first.
#
# Usage:  sim/gust-wasmtime.sh                 # fetch gale's gust_kernel.wasm + run
#         WASM=/path/gust_kernel.wasm sim/gust-wasmtime.sh
set -euo pipefail
command -v wasmtime >/dev/null || { echo "wasmtime absent"; exit 2; }
WASM="${WASM:-}"
if [ -z "$WASM" ] || [ ! -f "$WASM" ]; then
  WASM=/tmp/gust_kernel.wasm
  gh api repos/pulseengine/gale/contents/benches/gust/wasm-kernel/gust_kernel.wasm --jq '.content' | base64 -d > "$WASM"
fi
# wasmtime 42: --invoke <func> <module> <arg...> (experimental warnings -> stderr)
got=$(wasmtime run --invoke gust_mix "$WASM" 1024 2>/dev/null | tr -dc '0-9')
echo "gust (wasmtime, hardware-free): gust_mix(1024) = ${got:-<none>}  (expect 1500)"
if [ "$got" = "1500" ]; then
  echo "ORACLE PASS: failsafe mixer correct in wasmtime SIL (matches the silicon kill-criterion)."
  exit 0
else
  echo "ORACLE FAIL: gust_mix(1024) = ${got:-<none>} != 1500"; exit 1
fi
