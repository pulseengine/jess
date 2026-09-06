#!/usr/bin/env bash
# Build the embedder-init on-target image for the STM32F100 (Cortex-M3).
#
# Chain: probe.wat -> wasm-tools -> synth --relocatable --embedder-data-init
#        --embedder-global-init -> extract_init.py (tables) -> apply_init.c (the
#        loop that CONSUMES them) -> boot.S -> one 8 KB-safe ELF.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$D/../../../.scratch/f100init}"; mkdir -p "$OUT"
SYNTH="${SYNTH:?set SYNTH to a synth binary}"
PY="${PY:-python3}"
WT="${WASM_TOOLS:-wasm-tools}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v arm-none-eabi-gcc >/dev/null || fail "arm-none-eabi-gcc not on PATH"

"$WT" parse "$D/probe.wat" -o "$OUT/probe.wasm" || fail "wasm-tools parse"
"$SYNTH" compile "$OUT/probe.wasm" -t cortex-m3 --cortex-m --relocatable --all-exports \
    --embedder-data-init --embedder-global-init -o "$OUT/probe.o" >"$OUT/lower.log" 2>&1 \
  || { cat "$OUT/lower.log"; fail "probe did not lower for cortex-m3"; }

"$PY" "$D/../../../tools/embedder-init/extract_init.py" "$OUT/probe.wasm" \
    --out-c "$OUT/init_tables.c" --out-manifest "$OUT/init.json" || fail "extraction failed"

CPU="-mcpu=cortex-m3 -mthumb"
arm-none-eabi-gcc -c $CPU -ffreestanding -O2 "$OUT/init_tables.c" -o "$OUT/init_tables.o" || fail "tables did not compile"
arm-none-eabi-gcc -c $CPU -ffreestanding -O2 "$D/apply_init.c"    -o "$OUT/apply_init.o"  || fail "apply loop did not compile"
arm-none-eabi-gcc -c $CPU "$D/boot.S" -o "$OUT/boot.o"            || fail "boot.S did not assemble"

arm-none-eabi-ld -T "$D/link.ld" -o "$OUT/f100init.elf" \
    "$OUT/boot.o" "$OUT/probe.o" "$OUT/apply_init.o" "$OUT/init_tables.o" \
  || fail "link failed"

left="$(arm-none-eabi-nm "$OUT/f100init.elf" | awk '$1=="U"||$2=="U"{print $NF}' | sort -u)"
[ -z "$left" ] || fail "undefined after linking: $left"

# The image must FIT the real part and must not place anything in RAM: every RAM
# address is established by boot.S, so a .data/.bss section would mean an
# initialiser nobody copies (AFD-088's geometry lesson, applied to this image).
ram=$(arm-none-eabi-readelf -S "$OUT/f100init.elf" | awk '/\.data|\.bss/{print $0}')
[ -z "$ram" ] || fail "image has RAM sections nothing initialises:
$ram"

# The embedder ABI gate. boot.S is the ONLY place allowed to write R9/R10/R11, and
# `reset` must be the symbol those writes are attributed to — a stray named label
# once stole the attribution, and an acknowledgement that names the wrong symbol
# acknowledges nothing. Needs synth >= 0.62 (verify-embedder); skipped, LOUDLY, if
# no such binary is given, because a silently-skipped gate is a vacuous gate.
if [ -n "${SYNTH_VERIFY:-}" ]; then
  "$SYNTH_VERIFY" verify-embedder --allow-writer reset "$OUT/f100init.elf" >"$OUT/ve.log" 2>&1     || { cat "$OUT/ve.log"; fail "embedder ABI violated (writes outside the reset establishment site)"; }
  # NEGATIVE CONTROL: without the acknowledgement the same image must be REFUSED.
  # Otherwise a verify-embedder that had lost the ability to refuse would pass above.
  if "$SYNTH_VERIFY" verify-embedder "$OUT/f100init.elf" >/dev/null 2>&1; then
    fail "verify-embedder ACCEPTED the image without --allow-writer — it can no longer refuse"
  fi
  echo "embedder ABI: OK (writes confined to <reset>; refusal still works unacknowledged)"
else
  echo "embedder ABI: NOT CHECKED (set SYNTH_VERIFY to a synth >= 0.62)"
fi

arm-none-eabi-objcopy -O binary "$OUT/f100init.elf" "$OUT/f100init.bin" || fail "objcopy"
sz=$(wc -c <"$OUT/f100init.bin")
[ "$sz" -gt 0 ] || fail "empty image"
echo "built $OUT/f100init.elf  ($sz B raw)"
arm-none-eabi-nm "$OUT/f100init.elf" | grep -E 'read_data|read_global|jess_wasm_apply_init|jess_wasm_data_seg_count|jess_wasm_global_count'
