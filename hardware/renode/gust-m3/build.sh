#!/usr/bin/env bash
# Rebuild the F100/M3 gust pass-through image (passthrough_mem.elf) for the on-target
# execution gate (TEST-PIX-028, passthrough-m3.robot). The committed ELF + the robot's
# linear-memory base are a MATCHED PAIR — regenerate both together on a newer synth.
#
#   synth compile passthrough_mem.wasm --cortex-m -t cortex-m3 \
#     --stack-layout low --stack-size 1024        (self-contained, bootable, FITS 8 KB)
#
# THE STACK FLAGS ARE NOT OPTIONAL (AFD-088). Without them synth's default `--stack-layout
# high` puts the initial SP at the top of an ASSUMED 128 KB SRAM (0x20020000). A real
# STM32F100 has 8 KB, so the first push faults — and the old 256 KB m3.repl hid that for six
# weeks. `low` reserves the stack at the BOTTOM of SRAM (SP = 0x20000400) and places linear
# memory above it, which fits the real part. Verify with ./check-fits-real-f100.sh.
#
# The self-contained reset calls the single export `entry`, which copies the 4 input
# per-motor words (linmem +0..12) to the output block (+16..28) byte-exact (pure i32
# load/store — no float, no re-mix). Linear-memory base is printed in `entry`'s prologue
# (synth v0.58 + --stack-layout low = 0x20000500); if it changes, update the *_ADDR
# variables in passthrough-m3.robot to match.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
SYNTH="${SYNTH:?set SYNTH to a synth binary (>= v0.49)}"
WT="${WASM_TOOLS:-wasm-tools}"

"$WT" parse "$D/passthrough_mem.wat" -o "$D/passthrough_mem.wasm"
"$SYNTH" compile "$D/passthrough_mem.wasm" --cortex-m -t cortex-m3 \
  --stack-layout low --stack-size "${STACK_SIZE:-1024}" -o "$D/passthrough_mem.elf"
# Fail the build rather than emit an image that cannot run on the part it is evidence about.
"$D/check-fits-real-f100.sh" "$D/passthrough_mem.elf"
base=$( (arm-none-eabi-objdump -d "$D/passthrough_mem.elf" 2>/dev/null || llvm-objdump -d "$D/passthrough_mem.elf") \
        | sed -n '/<entry>:/,/ldr/p' | grep -oE 'movt.*0x2000' | head -1 || true )
echo "built $D/passthrough_mem.elf ($(wc -c <"$D/passthrough_mem.elf") bytes) — verify the robot's linmem base matches (entry rebases fp; synth v0.58 --stack-layout low = 0x20000500)."
