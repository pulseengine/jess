#!/usr/bin/env bash
# Physical on-silicon oracle for REQ-PIX-009 / TEST-PIX-016 (the literal-silicon
# rung gale's REFLASH.md + synth#383 flagged as "pending hardware").
#
# Board: STM32VLDISCOVERY (STM32F100RBT6B — Cortex-M3, 128KB flash @0x08000000,
# 8KB SRAM @0x20000000, ONBOARD ST-LINK over USB). The dissolved gust kernel
# (gale benches/gust, synth v0.11.51 #383 shrink, bss 4256 / ~4.8KB working set)
# prints its heartbeat via SEMIHOSTING (hprintln), so we flash + run under a
# debugger that forwards semihosting.
#
# Interface jess has: openocd 0.12.0 (ST-LINK + stm32f1x). probe-rs / st-flash
# are the REFLASH.md alternatives; this script uses the openocd path.
#
# NOTE: this is the STANDALONE eval board, NOT the Pixhawk vehicle — flashing it
# is fine. (The Pixhawk F100 stays READ-ONLY / greenlight-gated.)
#
# Usage:  hardware/silicon/gust-vldiscovery-flash.sh            # fetch gale elf + flash + run
#         ELF=/path/to/gust_wasm.elf  hardware/silicon/gust-vldiscovery-flash.sh
set -euo pipefail
GDB="${GDB:-arm-none-eabi-gdb}"
OPENOCD="${OPENOCD:-openocd}"
ELF="${ELF:-}"

# 0. board present?
command -v "$OPENOCD" >/dev/null || { echo "openocd absent (brew install open-ocd)"; exit 2; }
"$OPENOCD" -f interface/stlink.cfg -f target/stm32f1x.cfg -c "init; reset halt; flash banks; shutdown" 2>/tmp/ocd.log \
  || { echo "FAIL: no ST-LINK / board not connected. Plug the STM32VLDISCOVERY (USB)."; tail -5 /tmp/ocd.log; exit 3; }

# 1. get the dissolved gust elf (gale benches/gust; not vendored to avoid stale binary)
if [ -z "$ELF" ]; then
  ELF=/tmp/gust_wasm.elf
  gh api repos/pulseengine/gale/contents/benches/gust/renode-test/gust_wasm.elf --jq '.content' \
    | base64 -d > "$ELF"
fi
echo "flashing $ELF ($(wc -c <"$ELF"|tr -d ' ') bytes) to STM32F100RB @0x08000000"

# 2. flash + run with semihosting, capture the heartbeat
HB=/tmp/gust-silicon-heartbeat.txt; : > "$HB"
"$OPENOCD" -f interface/stlink.cfg -f target/stm32f1x.cfg \
  -c "init; arm semihosting enable; program $ELF verify reset; resume" >/tmp/ocd-run.log 2>&1 &
OCD=$!
# semihosting text lands in the openocd log; tail it for the heartbeat window
( sleep 30; kill $OCD 2>/dev/null || true ) &
wait $OCD 2>/dev/null || true
grep -aE 'gust|mix|poll rounds|scheduler' /tmp/ocd-run.log | tee "$HB" || true

# 3. oracle: match REFLASH.md's expected output (kill-criterion: HardFault / mix!=1500 / no heartbeat)
if grep -qE 'gust_mix\(1024\)=1500' "$HB" && grep -qE 'poll rounds, scheduler stable' "$HB"; then
  echo "ORACLE PASS: dissolved gust boots on real STM32F100 silicon (mix=1500, scheduler stable)."
  exit 0
else
  echo "ORACLE INCONCLUSIVE/FAIL: did not see mix=1500 + stable poll rounds. See /tmp/ocd-run.log."
  echo "(If the board is connected and this still fails, that is exactly the silicon refuse-geometry"
  echo " gap synth#383 wanted surfaced before tagging — report on synth#383.)"
  exit 1
fi
