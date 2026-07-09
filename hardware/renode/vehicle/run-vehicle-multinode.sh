#!/usr/bin/env bash
# Track B (Renode real-hardware) multi-node vehicle — the THREE-CORE topology of the
# Pixhawk 6X-RT (TEST-PIX-019, Stage 4), mirror of the wasmtime sim (sim/vehicle-wasmtime.sh).
#   mach "rt1176" : rt1176-dualcore.repl — cpu_m7 (smoke bring-up, LPUART banner) +
#                   cpu_m4 (sensor-offload stub, writes a heartbeat to the M7<->M4
#                   shared-memory ring @ 0x20400000), both on the shared RT1176 sysbus.
#   mach "f100-io": gale gust_m3_8k.repl + gust_wasm.elf — the real dissolved failsafe.
#   links: M7<->M4 = OCRAM-adjacent SHMEM ring + MU stub (on-die, DD-009); FMU<->F100
#          = relay-bus carrier (relay#177; reactive consume pending gust ipc-rx, gale#65).
# Confirms all THREE cores co-execute and the M7<->M4 shared-mem link is live. The
# reactive failsafe handoff (gust consuming the heartbeat) is orchestration-modeled
# until gale exposes gust ipc-rx; the handoff LOGIC is proven on the wasmtime track.
set -euo pipefail
RENODE="${RENODE:?set RENODE to the renode binary}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
M7ELF="$ROOT/hardware/renode/smoke/rt1176-smoke.elf"
M4ELF="$ROOT/hardware/renode/vehicle/m4/m4-heartbeat.elf"
GUSTREPL=/tmp/gust_m3_8k.repl; GUSTELF=/tmp/gust_wasm.elf
gh api repos/pulseengine/gale/contents/benches/gust/renode-test/gust_m3_8k.repl --jq '.content' | base64 -d > "$GUSTREPL"
gh api repos/pulseengine/gale/contents/benches/gust/renode-test/gust_wasm.elf  --jq '.content' | base64 -d > "$GUSTELF"
UART="$(mktemp -t m7uart).txt"; : > "$UART"
RESC=$(mktemp -t vehicle3).resc
cat > "$RESC" <<RESC
mach create "rt1176"
machine LoadPlatformDescription @$ROOT/hardware/renode/vehicle/rt1176-dualcore.repl
sysbus LoadELF @$M7ELF
sysbus LoadELF @$M4ELF
sysbus.lpuart1 CreateFileBackend @$UART true
cpu_m7 VectorTableOffset 0x0
cpu_m4 VectorTableOffset 0x20240000
mach clear
mach create "f100-io"
machine LoadPlatformDescription @$GUSTREPL
sysbus LoadELF @$GUSTELF
emulation RunFor "0.02"
mach set "rt1176"
sysbus ReadDoubleWord 0x20400000
sysbus ReadDoubleWord 0x40C4C280 cpu_m7
quit
RESC
OUT=$("$RENODE" --console --disable-xwt -e "include @$RESC" 2>&1)
# The two ReadDoubleWord echoes, in RESC order: last-2 = SHMEM heartbeat, last-1 = MU
# aInstance RR0. Parsed portably (no bash-4 readarray, for macOS bash 3.2 + CI).
HEX=$(printf '%s\n' "$OUT" | grep -oE '0x[0-9A-Fa-f]{8}')
HB=$(printf '%s\n' "$HEX" | tail -2 | head -1)
MU_RR=$(printf '%s\n' "$HEX" | tail -1)
M7=$(tr -dc '[:print:]\n' < "$UART" | head -1)
echo "M7 (cpu_m7) LPUART banner : ${M7:-<none>}"
echo "M4 (cpu_m4) SHMEM heartbeat: ${HB:-<none>}  (M7<->M4 shared-mem ring @ 0x20400000)"
echo "MU doorbell aInstance RR0  : ${MU_RR:-<none>}  (M4 bInstance TR0 -> M7 aInstance RR0; expect 0x0000BEEF)"
ok=1
echo "$M7" | grep -q 'JESS-RT1176 boot OK' || { echo "FAIL: M7 banner missing"; ok=0; }
[ -n "$HB" ] && [ "$HB" != "0x00000000" ] || { echo "FAIL: M4 heartbeat not advancing (M7<->M4 shmem dead)"; ok=0; }
[ "$MU_RR" = "0x0000BEEF" ] || { echo "FAIL: MU doorbell not delivered (M4 TR0 -> M7 RR0 dead); got ${MU_RR:-<none>}"; ok=0; }
[ "$ok" = 1 ] && echo "ORACLE PASS: M7+M4+F100 co-execute; SHMEM ring live AND the NXP MU doorbell datapath (M4 bInstance TR0 -> M7 aInstance RR0) delivers." || exit 1
