#!/usr/bin/env bash
# Does the gust pass-through image actually FIT the part it claims to be evidence for?
#
# TEST-PIX-028 runs passthrough_mem.elf on hardware/renode/gust-m3/m3.repl and is cited as the
# ON-TARGET rung for REQ-PIX-004 PART-P02 - the F100 failsafe core, i.e. the Pixhawk 6X-RT's
# real STM32F100 IO coprocessor. m3.repl is a SYNTHETIC "STM32F100-class" platform and gives
# itself 256 KB of SRAM. The real part has 8 KB. Read off actual STM32F100 silicon on 2026-09-05
# (an STM32VLDISCOVERY on the Pi bench, via SWD):
#     DBGMCU_IDCODE 0x10016420  -> DEV_ID 0x420, STM32F100 value line
#     flash size    0x1FFFF7E0  -> 0x0080 = 128 KB
#     initial MSP   0x20002000              => 8 KB SRAM, top at 0x20002000
#
# An emulator that is MORE GENEROUS than the target does not fail the way the target fails; it
# passes. That is how an on-target claim can be green about a machine that cannot exist.
#
# This asserts the image against the REAL geometry. Exit 0 = fits; exit 1 = the evidence does
# not transfer to silicon.
set -uo pipefail
cd "$(dirname "$0")"
ELF=${1:-passthrough_mem.elf}

# Real STM32F100 (value line, 128 KB flash part as measured):
SRAM_BASE=$((0x20000000)); SRAM_SIZE=$((8 * 1024))
SRAM_TOP=$((SRAM_BASE + SRAM_SIZE))
FLASH_SIZE=$((128 * 1024))

for t in arm-none-eabi-readelf readelf; do command -v $t >/dev/null && RE=$t && break; done
for t in arm-none-eabi-objcopy objcopy; do command -v $t >/dev/null && OC=$t && break; done
[ -n "${RE:-}" ] && [ -n "${OC:-}" ] || { echo "need readelf + objcopy"; exit 2; }

# Initial MSP is the first word of the vector table.
"$OC" -O binary --only-section=.text "$ELF" /tmp/.vt.bin 2>/dev/null || \
  "$OC" -O binary "$ELF" /tmp/.vt.bin
MSP=$(od -An -tx4 -N4 /tmp/.vt.bin | tr -d ' ')
MSP=$((16#$MSP))

fail=0
printf "image:            %s\n" "$ELF"
printf "real F100 SRAM:   %#010x .. %#010x  (%d KB)\n" "$SRAM_BASE" "$SRAM_TOP" $((SRAM_SIZE/1024))
printf "initial MSP:      %#010x  " "$MSP"
if [ "$MSP" -gt "$SRAM_TOP" ] || [ "$MSP" -lt "$SRAM_BASE" ]; then
  printf "*** OUTSIDE PHYSICAL SRAM — the first stack push faults on real silicon ***\n"; fail=1
else printf "ok\n"; fi

# Every RW/LOAD segment placed in SRAM must fit inside 8 KB.
"$RE" -l "$ELF" 2>/dev/null | awk '/LOAD/{print $3, $6}' | while read -r vaddr memsz; do
  v=$((vaddr)); m=$((memsz))
  case $((v >= SRAM_BASE && v < SRAM_BASE + 0x10000000)) in
    1) end=$((v + m))
       printf "SRAM segment:     %#010x + %#x = %#010x  " "$v" "$m" "$end"
       if [ "$end" -gt "$SRAM_TOP" ]; then
         printf "*** OVERFLOWS 8 KB by %d bytes ***\n" $((end - SRAM_TOP)); echo OVERFLOW >> /tmp/.f100fail
       else printf "fits\n"; fi ;;
  esac
done
[ -f /tmp/.f100fail ] && { fail=1; rm -f /tmp/.f100fail; }

if [ "$fail" -ne 0 ]; then
  echo
  echo "Result: FAIL — this image cannot run on a real STM32F100."
  echo "  TEST-PIX-028 is green in Renode because hardware/renode/gust-m3/m3.repl declares"
  echo "  256 KB of SRAM. The target part has 8 KB. The emulator is more generous than the"
  echo "  hardware, so it does not reproduce the failure the hardware would have."
  exit 1
fi
echo "Result: PASS — fits the real STM32F100 geometry."
