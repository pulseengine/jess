#!/usr/bin/env bash
# NEGATIVE CONTROL for the silicon run. The outputs are READ FROM SRAM, so "outputs == inputs"
# is only evidence the PROGRAM wrote them if a non-run would look different. Poison the output
# words with a sentinel first, then vary exactly one thing: whether the CPU is resumed.
set -uo pipefail
OOCD="sudo -n openocd -f interface/stlink-hla.cfg -f target/stm32f1x.cfg"
IN0=0x20000500; OUT0=0x20000510
M=(0x3f266666 0x3f266666 0x3f266666 0x3f266666)

poison_and() { # $1 = "resume" | "norun"
  local act=$1
  local cmds=(-c "init" -c "reset halt"
    -c "mww $IN0 ${M[0]}" -c "mww $((IN0+4)) ${M[1]}" -c "mww $((IN0+8)) ${M[2]}" -c "mww $((IN0+12)) ${M[3]}"
    -c "mww $OUT0 0xDEADBEEF" -c "mww $((OUT0+4)) 0xDEADBEEF"
    -c "mww $((OUT0+8)) 0xDEADBEEF" -c "mww $((OUT0+12)) 0xDEADBEEF")
  if [ "$act" = resume ]; then cmds+=(-c "resume" -c "sleep 100" -c "halt"); fi
  cmds+=(-c "mdw $OUT0 4" -c "shutdown")
  $OOCD "${cmds[@]}" 2>&1 | grep -E "^0x20000510" | sed 's/^0x20000510: //' | tr -s ' ' | sed 's/ *$//'
}

echo "sentinel written to all four OUTPUT words = deadbeef; inputs = hover row 3f266666 x4"
echo
a=$(poison_and norun)
echo "  CPU NOT resumed : $a"
b=$(poison_and resume)
echo "  CPU resumed     : $b"
echo
if [ "$a" = "deadbeef deadbeef deadbeef deadbeef" ]; then
  echo "  control CAN observe a non-run (sentinel survives when the program does not execute)"
else
  echo "  *** CONTROL IS VACUOUS: the sentinel did not survive even without running ***"
fi
if [ "$b" = "3f266666 3f266666 3f266666 3f266666" ]; then
  echo "  and the program DID execute: it overwrote the sentinel with the input words"
else
  echo "  *** the resumed run did not produce the inputs ***"
fi
