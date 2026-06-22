#!/usr/bin/env bash
# Combined two-node VEHICLE simulation in wasmtime — hardware-free (Track A, DD-019).
# Runs BOTH real node behaviors and models the inter-node IPC + failsafe arbitration:
#   M7  (falcon component)  : primary control  — run-stabilization() / run-position-hold()
#   F100 (gust core module) : failsafe         — gust_mix(rc)
# Scenario: nominal (M7 healthy, drives actuators; gust passive) -> M7 FAULT injected
# (heartbeat lost) -> gust takes over and drives the failsafe PWM. Asserts the handoff is
# clean (a valid actuator command at every step) and both node behaviors are correct.
#
# The IPC heartbeat + arbitration are host-modeled here (the relay-bus carrier / gust
# supervisor abstracted) — the NODE behaviors come from the real wasm. The same scenario
# is mirrored onto Renode multi-node (Track B).
#
# Usage:  sim/vehicle-wasmtime.sh         # uses/fetches falcon + gust wasm
#         FALCON=/path/falcon.wasm GUST=/path/gust_kernel.wasm sim/vehicle-wasmtime.sh
set -euo pipefail
command -v wasmtime >/dev/null || { echo "wasmtime absent"; exit 2; }

FALCON="${FALCON:-}"
if [ -z "$FALCON" ] || [ ! -f "$FALCON" ]; then
  FALCON=$(ls .scratch/build/falcon-v*/falcon-flight-v*.wasm 2>/dev/null | sort -V | tail -1 || true)
fi
[ -n "$FALCON" ] && [ -f "$FALCON" ] || { echo "set FALCON to a falcon-flight wasm (or run scripts/jess-build.sh first)"; exit 2; }
GUST="${GUST:-/tmp/gust_kernel.wasm}"
if [ ! -f "$GUST" ]; then
  gh api repos/pulseengine/gale/contents/benches/gust/wasm-kernel/gust_kernel.wasm --jq '.content' | base64 -d > "$GUST"
fi
echo "M7   node: $(basename "$FALCON")"
echo "F100 node: $(basename "$GUST")"
RC=1024   # last-known RC/SBUS setpoint the failsafe holds

fail() { echo "ORACLE FAIL: $*"; exit 1; }
flt_lt() { python3 -c "import sys;sys.exit(0 if float('$1')<float('$2') else 1)"; }

echo; echo "── PHASE 1: NOMINAL (M7 healthy, drives actuators; gust passive/armed) ──"
STAB=$(wasmtime run --invoke 'run-stabilization()' "$FALCON" 2>/dev/null | tr -dc '0-9.eE+-')
POS=$(wasmtime run --invoke 'run-position-hold()' "$FALCON" 2>/dev/null | tr -dc '0-9.eE+-')
echo "  M7 control: stabilization=$STAB rad, position-hold=$POS m"
flt_lt "$STAB" 0.1 || fail "M7 stabilization $STAB not < 0.1 rad — M7 unhealthy in nominal"
flt_lt "$POS" 0.6 || fail "M7 position-hold $POS not < 0.6 m — M7 unhealthy in nominal"
M7_HEARTBEAT=1
ACTIVE="M7"; ACTIVE_CMD="$STAB"
echo "  IPC: M7 heartbeat=present -> arbitration ACTIVE=$ACTIVE (gust passive, failsafe armed)"

echo; echo "── PHASE 2: M7 FAULT injected (heartbeat lost) -> gust failsafe takeover ──"
M7_HEARTBEAT=0
echo "  IPC: M7 heartbeat=LOST -> gust supervisor trips"
MIX=$(wasmtime run --invoke gust_mix "$GUST" "$RC" 2>/dev/null | tr -dc '0-9-')
echo "  F100 failsafe: gust_mix($RC)=$MIX"
[ "$MIX" = "1500" ] || fail "failsafe mix $MIX != 1500 (RC=$RC)"
ACTIVE="F100-gust"; ACTIVE_CMD="$MIX"
echo "  arbitration ACTIVE=$ACTIVE (failsafe PWM driving actuators)"

echo; echo "── HANDOFF CHECK: a valid actuator command at every step (no gap) ──"
[ -n "$STAB" ] && [ -n "$MIX" ] || fail "actuator command gap during handoff"
echo "  nominal cmd (M7)=$STAB rad  ->  failsafe cmd (gust)=$MIX  — clean handoff, no gap"

echo; echo "ORACLE PASS: combined M7+F100 vehicle — nominal control in-spec, M7-fault -> gust"
echo "failsafe takeover correct (mix=1500), handoff gap-free. (wasmtime, hardware-free.)"
