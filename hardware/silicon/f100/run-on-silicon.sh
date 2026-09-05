#!/usr/bin/env bash
# H2 / AFD-088 step 3: run the synth-compiled gust pass-through on REAL STM32F100 silicon
# and assert byte-exactness against the SAME relay fixture rows the Renode oracle uses.
# Recovery: ~/bench/f100-backup/original-flash.bin (128 KB, sha256 10969f5c...) restores the board.
set -uo pipefail

# SELF-CLAIM the probe rather than trusting the caller to. The README asserted "everything here
# runs under a with-device stlink-v1 claim" while neither script took one — true of how they were
# invoked by hand, false of the scripts as committed, so anyone running them straight would drive
# a probe gale may be holding. That is the AFD-082 vacuous-lock shape in documentation form, and
# it was found by an independent verifier, not by re-reading the file.
#
# Re-exec under with-device unless we are already inside it. The WD_REENTRY guard (rather than
# $WITH_DEVICE_CLAIM) is deliberate: the bench currently runs with-device 0.2.1, which does not
# export that variable — keying on it would make this silently never re-exec there.
WD="${WITH_DEVICE:-$HOME/bench/with-device}"
if [ -z "${WD_REENTRY:-}" ] && [ -x "$WD" ]; then
  export WD_REENTRY=1
  exec "$WD" stlink-v1 --purpose "H2: synth image on real F100 silicon" -- "$0" "$@"
fi
OOCD="sudo -n openocd -f interface/stlink-hla.cfg -f target/stm32f1x.cfg"
IN0=0x20000500; OUT0=0x20000510

# DERIVE the raw image here. This script used to consume a /tmp/pt.bin that NO committed step
# produced — it existed only on the machine where it had once been made by hand, so from a
# clean checkout the script could not run at all. Found by an independent verifier; it is the
# same unreproducible-input defect AFD-075 recorded for appcompose, in a second place.
ELF="${ELF:-$(cd "$(dirname "$0")/../../renode/gust-m3" && pwd)/passthrough_mem.elf}"
BIN="${BIN:-/tmp/pt.bin}"
for t in arm-none-eabi-objcopy objcopy; do command -v $t >/dev/null && OC=$t && break; done
[ -n "${OC:-}" ] || { echo "need objcopy"; exit 2; }
[ -f "$ELF" ] || { echo "missing $ELF"; exit 2; }
"$OC" -O binary "$ELF" "$BIN" || { echo "objcopy failed"; exit 2; }
echo "image: $BIN ($(wc -c <"$BIN") B) derived from $ELF"

echo "=== flash the synth image at 0x08000000 (the ELF links .text at the 0x0 boot alias) ==="
$OOCD -c "init; halt" \
      -c "flash write_image erase "$BIN" 0x08000000" \
      -c "verify_image "$BIN" 0x08000000" \
      -c "shutdown" 2>&1 | grep -iE "wrote|verified|error|failed" | head -5

run_row() {
  local m0=$1 m1=$2 m2=$3 m3=$4
  $OOCD -c "init" -c "reset halt" \
    -c "mww $IN0 $m0" -c "mww $((IN0+4)) $m1" -c "mww $((IN0+8)) $m2" -c "mww $((IN0+12)) $m3" \
    -c "resume" -c "sleep 100" -c "halt" \
    -c "mdw $OUT0 4" -c "shutdown" 2>&1 | grep -E "^0x20000510" | head -1
}

echo
echo "=== the three fixture rows, on silicon ==="
printf "%-46s %s\n" "ROW (inputs)" "OUTPUTS READ BACK FROM SILICON"
for row in \
  "0x00000000 0x3f3ccbcb 0x00000000 0x3f3ccbcb|rotor-out, motors 0+2 ZEROED (safety-critical)" \
  "0x3f266666 0x3f266666 0x3f266666 0x3f266666|hover" \
  "0x3ee77cd9 0x3ef38916 0x3eeb7bad 0x3edf8454|saturated" ; do
  vals=${row%%|*}; label=${row##*|}
  set -- $vals
  out=$(run_row "$1" "$2" "$3" "$4")
  got=$(echo "$out" | sed 's/^0x20000510: //' | tr -s ' ' | sed 's/ *$//')
  want=$(printf "%s %s %s %s" "${1#0x}" "${2#0x}" "${3#0x}" "${4#0x}")
  if [ "$got" = "$want" ]; then verdict="BYTE-EXACT OK"; else verdict="*** MISMATCH ***"; fi
  printf "  %-44s %s   %s\n" "$label" "$got" "$verdict"
  printf "  %-44s %s   (expected)\n" "" "$want"
done
