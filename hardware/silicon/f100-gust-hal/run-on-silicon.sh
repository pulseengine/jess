#!/usr/bin/env bash
# H3 first half: gust:hal read32/write32 doing REAL MMIO on a real STM32F100.
#
# Both legs run the BYTE-IDENTICAL flashed image and differ in exactly ONE word —
# CLOCK_EN at 0x20000480, written by this host before `resume`. With it, GPIOC is
# clocked and the ODR write sticks; without it the peripheral is unclocked, the bus
# DROPS the writes, and the read-back is 0. The failing case is observable by
# construction, which is what makes the passing case evidence (AFD-048).
set -uo pipefail

WD="${WITH_DEVICE:-$HOME/bench/with-device}"
if [ -z "${WD_REENTRY:-}" ] && [ -x "$WD" ]; then
  export WD_REENTRY=1
  exec "$WD" stlink-v1 --purpose "gust:hal real MMIO on F100 silicon" -- "$0" "$@"
fi

OOCD="sudo -n openocd -f interface/stlink-hla.cfg -f target/stm32f1x.cfg"
CLOCK_EN=0x20000480; RES_ID=0x20000484; RES_ODR=0x20000488; DONE=0x2000048C

# Executed precondition, not a comment (AFD-107 (d)).
BACKUP="${BACKUP:-$HOME/bench/f100-backup/original-flash.bin}"
BACKUP_SHA=10969f5c35de715696c377c2ae367b9be5950698115f3f91adf479bb12a0a78b
if [ -z "${SKIP_BACKUP_CHECK:-}" ]; then
  [ -f "$BACKUP" ] || { echo "REFUSING TO WRITE: no recovery image at $BACKUP" >&2; exit 2; }
  got=$(sha256sum "$BACKUP" | awk '{print $1}')
  [ "$got" = "$BACKUP_SHA" ] || { echo "REFUSING TO WRITE: recovery hash mismatch" >&2
    echo "  expected $BACKUP_SHA" >&2; echo "  got      $got" >&2; exit 2; }
  echo "recovery image verified: $BACKUP"
fi

BIN="${BIN:-$HOME/bench/f100hal.bin}"
[ -f "$BIN" ] || { echo "missing image: $BIN"; exit 2; }
echo "image: $BIN ($(wc -c <"$BIN") B)"

echo "=== flash at 0x08000000 ==="
$OOCD -c "init; halt" -c "flash write_image erase $BIN 0x08000000" \
      -c "verify_image $BIN 0x08000000" -c "shutdown" 2>&1 | grep -iE "wrote|verified|error" | head -4

run_leg() {
  $OOCD -c "init" -c "reset halt" -c "mww $CLOCK_EN $1" \
    -c "resume" -c "sleep 200" -c "halt" \
    -c "mdw $RES_ID 1" -c "mdw $RES_ODR 1" -c "mdw $DONE 1" \
    -c "shutdown" 2>&1 | grep -E "^0x2000048"
}

echo
printf "%-40s %-11s %-11s %s\n" "LEG (only the CLOCK_EN word differs)" "IDCODE" "GPIOC_ODR" "completion"
rc=0
for leg in "1|GPIOC clocked (baseline)|300" "0|clock NOT enabled (neg. control)|00000000"; do
  IFS='|' read -r flag label want <<EOF
$leg
EOF
  out=$(run_leg "$flag")
  id=$(echo "$out" | grep "^0x20000484" | awk '{print $2}')
  odr=$(echo "$out" | grep "^0x20000488" | awk '{print $2}')
  c=$(echo "$out" | grep "^0x2000048c" | awk '{print $2}')
  ok="OK"
  # DEV_ID[11:0] must be 0x420 — a value nothing in the program contains. The stub
  # would have returned 0xE0042000 ^ 0x1E55_0000 = 0xFE51_2000 instead.
  dev=$(( 0x${id:-0} & 0xFFF ))
  [ "$dev" = "$((0x420))" ] || { ok="*** IDCODE DEV_ID=0x$(printf %03x $dev), want 0x420 ***"; rc=1; }
  [ "$((0x${odr:-0}))" = "$((0x$want))" ] || { ok="$ok *** ODR $odr, want $want ***"; rc=1; }
  [ "$c" = "c0ffee00" ] || { ok="$ok (DID NOT COMPLETE: $c)"; rc=1; }
  printf "  %-38s %-11s %-11s %-9s %s\n" "$label" "$id" "$odr" "$c" "$ok"
done
echo
[ $rc -eq 0 ] && echo "PASS — gust:hal read32/write32 performed REAL MMIO on real silicon." || echo "FAIL"
exit $rc
