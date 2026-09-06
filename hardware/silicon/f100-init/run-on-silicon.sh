#!/usr/bin/env bash
# Discharge AFD-046's two instantiation promises ON REAL STM32F100 SILICON.
#
# The BASELINE and the NEGATIVE CONTROL run the BYTE-IDENTICAL flashed image and
# differ in exactly ONE word: the APPLY flag at 0x20000480, written by this host
# before `resume`. Nothing else varies — not the binary, not the poison, not the
# reset path (AFD-048: a control that varies more than one thing measures the
# wrong thing, and one shipped in a merged safety artifact).
#
# Recovery: ~/bench/f100-backup/original-flash.bin (128 KB,
# sha256 10969f5c35de715696c377c2ae367b9be5950698115f3f91adf479bb12a0a78b)
# restores the board; verified byte-identical on read-back (AFD-091).
set -uo pipefail

# Self-claim the probe rather than trusting the caller (AFD-082): gale drives the
# same ST-Link. WD_REENTRY (not $WITH_DEVICE_CLAIM) because the bench runs
# with-device 0.2.1, which does not export that variable.
WD="${WITH_DEVICE:-$HOME/bench/with-device}"
if [ -z "${WD_REENTRY:-}" ] && [ -x "$WD" ]; then
  export WD_REENTRY=1
  exec "$WD" stlink-v1 --purpose "embedder-init: data segments + R9 globals on real F100" -- "$0" "$@"
fi

OOCD="sudo -n openocd -f interface/stlink-hla.cfg -f target/stm32f1x.cfg"

# RE-CHECK THE RECOVERY IMAGE BEFORE WRITING FLASH.
# The sha256 above used to appear only in a comment, while both this script and the
# README asserted the hash "is re-checked before any write" — an automated property
# nothing performed. Found by clean-room verification. A recovery path that is only
# claimed is not a recovery path, so it is now an executed precondition.
BACKUP="${BACKUP:-$HOME/bench/f100-backup/original-flash.bin}"
BACKUP_SHA=10969f5c35de715696c377c2ae367b9be5950698115f3f91adf479bb12a0a78b
if [ -z "${SKIP_BACKUP_CHECK:-}" ]; then
  [ -f "$BACKUP" ] || { echo "REFUSING TO WRITE: no recovery image at $BACKUP" >&2; exit 2; }
  got=$(sha256sum "$BACKUP" | awk '{print $1}')
  [ "$got" = "$BACKUP_SHA" ] || {
    echo "REFUSING TO WRITE: recovery image hash mismatch" >&2
    echo "  expected $BACKUP_SHA" >&2; echo "  got      $got" >&2; exit 2; }
  echo "recovery image verified: $BACKUP ($BACKUP_SHA)"
fi
APPLY=0x20000480; RES_DATA=0x20000484; RES_GLOB=0x20000488; DONE=0x2000048C
BIN="${BIN:-$HOME/bench/f100init.bin}"
[ -f "$BIN" ] || { echo "missing image: $BIN"; exit 2; }
echo "image: $BIN ($(wc -c <"$BIN") B)"

echo "=== flash at 0x08000000 ==="
$OOCD -c "init; halt" \
      -c "flash write_image erase $BIN 0x08000000" \
      -c "verify_image $BIN 0x08000000" \
      -c "shutdown" 2>&1 | grep -iE "wrote|verified|error|failed" | head -5

run_leg() {  # $1 = value written to the APPLY flag
  $OOCD -c "init" -c "reset halt" \
    -c "mww $APPLY $1" \
    -c "resume" -c "sleep 200" -c "halt" \
    -c "mdw $RES_DATA 1" -c "mdw $RES_GLOB 1" -c "mdw $DONE 1" \
    -c "shutdown" 2>&1 | grep -E "^0x2000048" 
}

echo
printf "%-34s %-11s %-11s %s\n" "LEG (only the APPLY word differs)" "read_data" "read_global" "completion"
rc=0
for leg in "1|init APPLIED (baseline)|44332211|5a5a0000" \
           "0|init SKIPPED (neg. control)|deadbeef|deadbeef" ; do
  IFS='|' read -r flag label wd wg <<EOF
$leg
EOF
  out=$(run_leg "$flag")
  d=$(echo "$out" | grep "^0x20000484" | awk '{print $2}')
  g=$(echo "$out" | grep "^0x20000488" | awk '{print $2}')
  c=$(echo "$out" | grep "^0x2000048c" | awk '{print $2}')
  ok="OK"
  [ "$d" = "$wd" ] && [ "$g" = "$wg" ] || { ok="*** MISMATCH ***"; rc=1; }
  # The completion marker proves the program RAN to the end. Without it, a
  # deadbeef row is equally consistent with "the CPU never resumed".
  [ "$c" = "c0ffee00" ] || { ok="$ok (DID NOT COMPLETE: $c)"; rc=1; }
  printf "  %-32s %-11s %-11s %-9s %s\n" "$label" "$d" "$g" "$c" "$ok"
  printf "  %-32s %-11s %-11s\n" "" "$wd" "$wg"
done
echo
[ $rc -eq 0 ] && echo "PASS — the emitted tables were APPLIED and the applying MATTERED." \
             || echo "FAIL"
exit $rc
