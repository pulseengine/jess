#!/usr/bin/env bash
# Rebuild the F100/M3 gust pass-through image (passthrough_mem.elf) for the on-target
# execution gate (TEST-PIX-028, passthrough-m3.robot). The committed ELF + the robot's
# linear-memory base are a MATCHED PAIR — regenerate both together on a newer synth.
#
#   synth compile passthrough_mem.wasm --cortex-m -t cortex-m3  (self-contained, bootable)
#
# The self-contained reset calls the single export `entry`, which copies the 4 input
# per-motor words (linmem +0..12) to the output block (+16..28) byte-exact (pure i32
# load/store — no float, no re-mix). Linear-memory base is printed in `entry`'s prologue
# (synth v0.49 = 0x20000100, a 0x100 reserved prefix); if it changes, update the *_ADDR
# variables in passthrough-m3.robot to match.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
SYNTH="${SYNTH:?set SYNTH to a synth binary (>= v0.49)}"
WT="${WASM_TOOLS:-wasm-tools}"

"$WT" parse "$D/passthrough_mem.wat" -o "$D/passthrough_mem.wasm"
"$SYNTH" compile "$D/passthrough_mem.wasm" --cortex-m -t cortex-m3 -o "$D/passthrough_mem.elf"
base=$( (arm-none-eabi-objdump -d "$D/passthrough_mem.elf" 2>/dev/null || llvm-objdump -d "$D/passthrough_mem.elf") \
        | sed -n '/<entry>:/,/ldr/p' | grep -oE 'movt.*0x2000' | head -1 || true )
echo "built $D/passthrough_mem.elf ($(wc -c <"$D/passthrough_mem.elf") bytes) — verify the robot's linmem base matches (entry rebases fp; synth v0.49 = 0x20000100)."
