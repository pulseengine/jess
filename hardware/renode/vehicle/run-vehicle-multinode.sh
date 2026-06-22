#!/usr/bin/env bash
# Track B (Renode real-hardware) mirror of the combined-vehicle wasmtime sim
# (sim/vehicle-wasmtime.sh): BOTH nodes as real ARM binaries in ONE Renode emulation.
#   M7 (FMU)  : pixhawk6xrt.repl + a bring-up firmware  (real falcon pending #369/#275)
#   F100 (IO) : gale gust_m3_8k.repl + gust_wasm.elf     (the real dissolved failsafe)
#   IPC link  : a Renode UARTHub (the relay-bus carrier proxy, relay#177 / DD-009)
# Confirms the multi-node TOPOLOGY: both real node binaries co-execute in one emulation
# joined by the inter-node link. The reactive failsafe handoff (gust consuming the M7
# heartbeat over ipc-rx) needs a gust ipc-rx build (gale) + real falcon on the M7; until
# then the handoff is orchestration-modeled (pausing the M7 machine = fault injection),
# exactly as the wasmtime track host-models the arbitration.
set -euo pipefail
RENODE="${RENODE:?set RENODE to the renode binary}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
M7ELF="$ROOT/hardware/renode/smoke/rt1176-smoke.elf"
# fetch gale's gust artifacts (not vendored — avoid stale gale binary)
GUSTREPL=/tmp/gust_m3_8k.repl; GUSTELF=/tmp/gust_wasm.elf
gh api repos/pulseengine/gale/contents/benches/gust/renode-test/gust_m3_8k.repl --jq '.content' | base64 -d > "$GUSTREPL"
gh api repos/pulseengine/gale/contents/benches/gust/renode-test/gust_wasm.elf  --jq '.content' | base64 -d > "$GUSTELF"
RESC=$(mktemp -t vehicle).resc
cat > "$RESC" <<RESC
:name: jess vehicle multi-node (M7 + F100)
emulation CreateUARTHub "relaybus"
mach create "m7-fmu"
machine LoadPlatformDescription @$ROOT/hardware/renode/pixhawk6xrt.repl
sysbus LoadELF @$M7ELF
connector Connect sysbus.lpuart1 relaybus
mach clear
mach create "f100-io"
machine LoadPlatformDescription @$GUSTREPL
sysbus LoadELF @$GUSTELF
emulation RunFor "0.02"
echo "--- machines ---"
mach
echo "--- m7 executed ---"
mach set "m7-fmu"
sysbus.cpu ExecutedInstructions
echo "--- f100 executed ---"
mach set "f100-io"
sysbus.cpu ExecutedInstructions
quit
RESC
"$RENODE" --console --disable-xwt -e "include @$RESC" 2>&1 | grep -iE 'm7-fmu|f100-io|machines|executed|[0-9]{5,}|relaybus|fault|error' | tail -20
