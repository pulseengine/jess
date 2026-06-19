#!/usr/bin/env bash
# Local mechanical oracle for REQ-PIX-014 stage 2 (DD-008): boot the real PX4
# fmu-v6xrt firmware on jess's RT1176 Renode model and assert it reaches LPUART
# console output. Renode is a LOCAL dev dependency (not in the per-PR CI gate yet —
# the run is heavy + needs the PX4 fetch); this script is the reproducible oracle.
#
# Prereqs (see README.md): Renode installed; the PX4 image extracted to $PX4BIN.
# Usage: RENODE=~/renode-1.16.1/Contents/MacOS/renode PX4BIN=/tmp/px4-v6xrt.bin \
#        hardware/renode/px4/run-px4-boot.sh
set -euo pipefail
RENODE="${RENODE:?set RENODE to the renode binary}"
PX4BIN="${PX4BIN:?set PX4BIN to the extracted PX4 image}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
UART="$(mktemp -t px4uart).txt"; : > "$UART"
RESC="$(mktemp -t px4boot).resc"
cat > "$RESC" <<RESC
set PX4BIN @$PX4BIN
include @$ROOT/hardware/renode/px4/px4-boot.resc
sysbus.lpuart1 CreateFileBackend @$UART true
emulation RunFor "0.5"
quit
RESC
( cd "$ROOT" && "$RENODE" --console --disable-xwt -e "include @$RESC" ) >/dev/null 2>&1 || true
bytes=$(wc -c < "$UART" | tr -d ' ')
echo "PX4-on-Renode: LPUART1 emitted $bytes byte(s): $(head -c 32 "$UART" | tr -dc '[:print:]')"
if [ "$bytes" -ge 1 ]; then
  echo "ORACLE PASS: PX4 reached LPUART console output (stage-2 console milestone)."
  exit 0
else
  echo "ORACLE FAIL: no console output — boot regressed before LPUART."
  exit 1
fi
