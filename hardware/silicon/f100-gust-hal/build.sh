#!/usr/bin/env bash
# Build the gust:hal on-target image (H3 first half) for the STM32F100.
#
# probe.wat -> synth --relocatable (imports become `U read32`/`U write32`)
#   + gust_hal.c (the REAL MMIO seam, -ffixed-r9/-r10/-r11)
#   + boot.S     (establishes the embedder ABI, stores results)
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$D/../../../.scratch/f100hal}"; mkdir -p "$OUT"
SYNTH="${SYNTH:?set SYNTH to a synth binary}"
WT="${WASM_TOOLS:-wasm-tools}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v arm-none-eabi-gcc >/dev/null || fail "arm-none-eabi-gcc not on PATH"

"$WT" parse "$D/probe.wat" -o "$OUT/probe.wasm" || fail "wasm-tools parse"
"$SYNTH" compile "$OUT/probe.wasm" -t cortex-m3 --cortex-m --relocatable --all-exports \
    -o "$OUT/probe.o" >"$OUT/lower.log" 2>&1 \
  || { cat "$OUT/lower.log"; fail "probe did not lower for cortex-m3"; }

# The seam must actually BE a seam: if these are not undefined, the wasm is not
# calling out to gust:hal and the whole rung would be measuring nothing.
for s in read32 write32; do
  arm-none-eabi-nm "$OUT/probe.o" | grep -qE "^ +U $s\$" \
    || fail "$s is not an undefined symbol in the lowered object — the gust:hal seam is absent"
done
echo "gust:hal seam present: read32, write32 both undefined in the lowered object"

CPU="-mcpu=cortex-m3 -mthumb"
arm-none-eabi-gcc -c $CPU -ffreestanding -O2 \
    -ffixed-r9 -ffixed-r10 -ffixed-r11 "$D/gust_hal.c" -o "$OUT/gust_hal.o" \
  || fail "gust_hal.c did not compile"
arm-none-eabi-gcc -c $CPU "$D/boot.S" -o "$OUT/boot.o" || fail "boot.S did not assemble"

arm-none-eabi-ld -T "$D/link.ld" -o "$OUT/f100hal.elf" \
    "$OUT/boot.o" "$OUT/probe.o" "$OUT/gust_hal.o" || fail "link failed"

left="$(arm-none-eabi-nm "$OUT/f100hal.elf" | awk '$1=="U"||$2=="U"{print $NF}' | sort -u)"
[ -z "$left" ] || fail "undefined after linking: $left"
ram=$(arm-none-eabi-readelf -S "$OUT/f100hal.elf" | grep -E '\.data|\.bss')
[ -z "$ram" ] || fail "image has RAM sections nothing initialises: $ram"

if [ -n "${SYNTH_VERIFY:-}" ]; then
  command -v "$SYNTH_VERIFY" >/dev/null 2>&1 || [ -x "$SYNTH_VERIFY" ] \
    || fail "SYNTH_VERIFY='$SYNTH_VERIFY' is not an executable — that is 'could not run', not 'failed'"
  "$SYNTH_VERIFY" verify-embedder --allow-writer reset "$OUT/f100hal.elf" >"$OUT/ve.log" 2>&1 \
    || { cat "$OUT/ve.log"; fail "embedder ABI violated — gust_hal.c may have lost -ffixed-r9/-r10/-r11"; }
  if "$SYNTH_VERIFY" verify-embedder "$OUT/f100hal.elf" >/dev/null 2>&1; then
    fail "verify-embedder ACCEPTED the image without --allow-writer — it can no longer refuse"
  fi
  echo "embedder ABI: OK (writes confined to <reset>; refusal still works unacknowledged)"
elif [ -n "${REQUIRE_VERIFY:-}" ]; then
  fail "REQUIRE_VERIFY set but SYNTH_VERIFY is not — refusing to call this build gated"
else
  echo "embedder ABI: NOT CHECKED (set SYNTH_VERIFY to a synth >= 0.62)"
fi

arm-none-eabi-objcopy -O binary "$OUT/f100hal.elf" "$OUT/f100hal.bin" || fail "objcopy"
echo "built $OUT/f100hal.elf ($(wc -c <"$OUT/f100hal.bin") B raw)"
