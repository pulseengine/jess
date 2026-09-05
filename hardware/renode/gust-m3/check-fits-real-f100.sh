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
# This asserts the image against the REAL geometry: the initial stack pointer and the linear-
# memory base must land inside physical SRAM, and no INITIALISED data may sit past its top.
# A NOBITS reservation larger than SRAM is reported and tolerated — see the correction below.
# Exit 0 = fits; exit 1 = the evidence does not transfer to silicon.
set -uo pipefail
# Resolve the argument BEFORE cd, or a RELATIVE path silently resolves against the script's
# directory instead of the caller's — checking a different file than the one named.
if [ -n "${1:-}" ]; then
  case "$1" in /*) ELF="$1" ;; *) ELF="$(pwd)/$1" ;; esac
else
  ELF=""
fi
cd "$(dirname "$0")"
[ -n "$ELF" ] || ELF="$PWD/passthrough_mem.elf"

# Real STM32F100 geometry. SRAM_SIZE_OVERRIDE shrinks the assumed SRAM so a KNOWN-GOOD image
# can be made to fail on demand — the control that proves this gate can still go red at all.
# BE PRECISE ABOUT WHICH BRANCH IT REACHES: with the committed image it trips the LINMEM-BASE
# check (linmem 0x20000500 lands outside a shrunken SRAM), NOT the initialised-data-overflow
# branch. An earlier version of this comment claimed it exercised the fatal path; measured, it
# does not, and the wrong comment was nearly shipped.
#
# STILL UNEXERCISED, stated rather than glossed: the "INITIALISED data past the SRAM top"
# branch. Reaching it needs an image with a PROGBITS LOAD segment in SRAM, and synth places
# linear memory as NOBITS, so no artifact jess builds today can take it. It guards a real
# hazard (a loader writing past the part's RAM) and no test covers it. Exercising it needs a
# purpose-built ELF, which is worth doing before anything relies on that branch.
SRAM_SIZE_OVERRIDE="${SRAM_SIZE_OVERRIDE:-}"

# Real STM32F100 (value line, 128 KB flash part as measured):
SRAM_BASE=$((0x20000000)); SRAM_SIZE=$(( ${SRAM_SIZE_OVERRIDE:-0} > 0 ? SRAM_SIZE_OVERRIDE : 8 * 1024 ))
SRAM_TOP=$((SRAM_BASE + SRAM_SIZE))
FLASH_SIZE=$((128 * 1024))

for t in arm-none-eabi-readelf readelf; do command -v $t >/dev/null && RE=$t && break; done
for t in arm-none-eabi-objdump llvm-objdump objdump; do command -v $t >/dev/null && OD=$t && break; done
[ -n "${RE:-}" ] || { echo "need readelf"; exit 2; }

# Read the initial MSP — the first word of the vector table, at the start of .text.
#
# FAIL CLOSED, and via readelf rather than objcopy. The first version of this check shelled out
# to `objcopy -O binary`, and on a runner whose binutils has no ARM target that prints
# "Unable to recognise the format of the input file" and writes nothing. The value was then the
# EMPTY STRING, `[ "" -gt N ]` errors and evaluates FALSE, both range tests fell through, and
# the gate printed "initial MSP: 0000000000  ok" and exited 0 — a PASS on a file it could not
# read. That is precisely the vacuous-gate class this check exists to expose, shipped inside the
# check itself. An unreadable value is now a hard failure, never an "ok".
read_msp() {
  # .text's file offset from the section table, then the first 4 bytes, little-endian.
  local off size
  # readelf -S prints "  [ 4] .text  PROGBITS  <addr> <off> <size> ..." — the "[ 4]" index
  # is one or two fields depending on the number, so strip it before positional parsing.
  off=$("$RE" -S "$ELF" 2>/dev/null | sed 's/\[[ 0-9]*\]//' | awk '$1==".text"{print $4; exit}')
  [ -n "$off" ] || return 1
  od -An -tx4 -N4 -j $((16#$off)) "$ELF" 2>/dev/null | tr -d ' \n'
}
MSP_HEX=$(read_msp || true)
case "$MSP_HEX" in
  [0-9a-fA-F][0-9a-fA-F]*) : ;;
  *) echo "CANNOT READ the vector table from '$ELF' (readelf=$RE)."
     echo "Result: FAIL — refusing to report a verdict on a file this check could not parse."
     exit 1 ;;
esac
MSP=$((16#$MSP_HEX))

fail=0
printf "image:            %s\n" "$ELF"
printf "real F100 SRAM:   %#010x .. %#010x  (%d KB)\n" "$SRAM_BASE" "$SRAM_TOP" $((SRAM_SIZE/1024))
printf "initial MSP:      %#010x  " "$MSP"
if [ "$MSP" -gt "$SRAM_TOP" ] || [ "$MSP" -lt "$SRAM_BASE" ]; then
  printf "*** OUTSIDE PHYSICAL SRAM — the first stack push faults on real silicon ***\n"; fail=1
else printf "ok\n"; fi

# The SRAM reservation: report it, but do NOT fail on it alone.
#
# CORRECTION (2026-09-05, same day this check was written): the first version FAILED whenever
# a LOAD segment in SRAM exceeded 8 KB, and that was a FALSE POSITIVE. synth places the wasm
# linear memory in a `.linear_memory` section of type NOBITS with FileSiz 0 — a pure
# reservation. Nothing is written to it at load, and an image only faults if it ACCESSES past
# the real SRAM top. The gust pass-through touches fp+0 .. fp+28 and nothing else.
# Failing on the declared reservation measures the ELF's opinion, not the hardware's. That is
# the same error this whole finding is about, committed inside the check written to expose it.
# Process substitution, NOT a pipeline. A `... | while read` loop runs in a SUBSHELL, so it
# cannot set `fail` in the parent — the first version worked around that by touching
# /tmp/.f100fail, a fixed world-writable path. That was a defect in both directions, and the
# first was DEMONSTRATED by an independent verifier: a stray /tmp/.f100fail (any process can
# create it) turned this gate RED on a perfectly good image. The other direction is worse: if
# that append ever failed — unwritable or full /tmp, a restricted runner — no file appeared,
# `fail` stayed 0, and a genuine INITIALISED-data overflow printed its "fatal" line while the
# script exited 0 with "Result: PASS". A gate that reports PASS through a /tmp race is exactly
# the vacuous-gate shape this script exists to expose.
while read -r vaddr filesz memsz; do
  v=$((vaddr)); f=$((filesz)); m=$((memsz))
  [ "$v" -ge "$SRAM_BASE" ] || continue
  [ "$v" -lt $((SRAM_BASE + 0x10000000)) ] || continue
  end=$((v + m))
  printf "SRAM reservation: %#010x + %#x = %#010x  " "$v" "$m" "$end"
  if [ "$end" -le "$SRAM_TOP" ]; then printf "fits\n"
  elif [ "$f" -eq 0 ]; then
    printf "exceeds %d KB but FileSiz=0 (NOBITS) — a reservation, not a load; not fatal on its own\n" $((SRAM_SIZE/1024))
  else
    printf "*** %d bytes of INITIALISED data past the SRAM top — written at load, fatal ***\n" \
      $((end - SRAM_TOP))
    fail=1
  fi
done < <("$RE" -l "$ELF" 2>/dev/null | awk '/LOAD/{print $3, $5, $6}')

# What the image actually TOUCHES: synth rebases fp in `entry`'s prologue, so the linear-memory
# base is a movw/movt immediate pair. Scope the search to `entry` — a plain first-match grep
# picks up the reset handler's own movw and reports the STACK pointer as the linmem base, which
# is a wrong number that happens to fall in the right range.
if [ -n "${OD:-}" ]; then
  pro=$("$OD" -d "$ELF" 2>/dev/null | sed -n '/<entry>:/,/^$/p')
  lo=$(printf '%s' "$pro" | grep -m1 -oE 'movw[[:space:]]+fp, #[0-9]+' | grep -oE '[0-9]+$')
  hi=$(printf '%s' "$pro" | grep -m1 -oE 'movt[[:space:]]+fp, #[0-9]+' | grep -oE '[0-9]+$')
  if [ -n "${lo:-}" ] && [ -n "${hi:-}" ]; then
    lm=$(( (hi << 16) | lo ))
    printf "linmem base:      %#010x  " "$lm"
    if [ "$lm" -ge "$SRAM_BASE" ] && [ "$lm" -lt "$SRAM_TOP" ]; then printf "inside real SRAM\n"
    else printf "*** OUTSIDE real SRAM ***\n"; fail=1; fi
  else
    echo "linmem base:      (not located in <entry>; disassembler=${OD})"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "Result: FAIL — this image cannot run on a real STM32F100."
  echo "  TEST-PIX-028 is green in Renode because hardware/renode/gust-m3/m3.repl declares"
  echo "  256 KB of SRAM. The target part has 8 KB. The emulator is more generous than the"
  echo "  hardware, so it does not reproduce the failure the hardware would have."
  echo "  FIX: rebuild with --stack-layout low --stack-size <N> (synth >= 0.58) so the stack"
  echo "  is reserved at the BOTTOM of SRAM instead of assuming a 128 KB part."
  exit 1
fi
echo "Result: PASS — fits the real STM32F100 geometry."
