#!/usr/bin/env bash
# H2 / AFD-088 step 3: run the synth-compiled gust pass-through on REAL STM32F100 silicon
# and assert byte-exactness against the SAME relay fixture rows the Renode oracle uses.
# Recovery: ~/bench/f100-backup/original-flash.bin (128 KB, sha256 10969f5c...) restores the board.
set -uo pipefail
OOCD="sudo -n openocd -f interface/stlink-hla.cfg -f target/stm32f1x.cfg"
IN0=0x20000500; OUT0=0x20000510

echo "=== flash the synth image at 0x08000000 (the ELF links .text at the 0x0 boot alias) ==="
$OOCD -c "init; halt" \
      -c "flash write_image erase /tmp/pt.bin 0x08000000" \
      -c "verify_image /tmp/pt.bin 0x08000000" \
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
