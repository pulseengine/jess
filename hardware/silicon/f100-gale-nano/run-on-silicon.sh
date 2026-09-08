#!/usr/bin/env bash
# H3 second half: gale-nano 0.7.0's dispatch loop EXECUTING on real STM32F100 silicon.
#
# Both legs run the BYTE-IDENTICAL flashed image and differ in exactly ONE word — ADMIT
# at 0x20000480, written by this host before `resume`. With a task admitted, poll-round
# must reach jess's `poll-task`; without one it must not. Same control pair as the
# wasmtime oracle TEST-PIX-035, which is what makes this a DIFFERENTIAL rather than a
# fresh assertion.
set -uo pipefail

WD="${WITH_DEVICE:-$HOME/bench/with-device}"
if [ -z "${WD_REENTRY:-}" ] && [ -x "$WD" ]; then
  export WD_REENTRY=1
  exec "$WD" stlink-v1 --purpose "gale-nano dispatch loop on F100 silicon" -- "$0" "$@"
fi

OOCD="sudo -n openocd -f interface/stlink-hla.cfg -f target/stm32f1x.cfg"
ADMIT=0x20000480; COUNT=0x20000484; RES_H=0x20000488; DONE=0x2000048C; RES_ST=0x20000490

BACKUP="${BACKUP:-$HOME/bench/f100-backup/original-flash.bin}"
BACKUP_SHA=10969f5c35de715696c377c2ae367b9be5950698115f3f91adf479bb12a0a78b
if [ -z "${SKIP_BACKUP_CHECK:-}" ]; then
  [ -f "$BACKUP" ] || { echo "REFUSING TO WRITE: no recovery image at $BACKUP" >&2; exit 2; }
  got=$(sha256sum "$BACKUP" | awk '{print $1}')
  [ "$got" = "$BACKUP_SHA" ] || { echo "REFUSING TO WRITE: recovery hash mismatch" >&2; exit 2; }
  echo "recovery image verified"
fi

BIN="${BIN:-$HOME/bench/f100gale.bin}"
[ -f "$BIN" ] || { echo "missing image: $BIN"; exit 2; }
echo "image: $BIN ($(wc -c <"$BIN") B)"

echo "=== flash at 0x08000000 ==="
$OOCD -c "init; halt" -c "flash write_image erase $BIN 0x08000000" \
      -c "verify_image $BIN 0x08000000" -c "shutdown" 2>&1 | grep -iE "wrote|verified|error" | head -4

run_leg() {
  $OOCD -c "init" -c "reset halt" -c "mww $ADMIT $1" \
    -c "resume" -c "sleep 300" -c "halt" \
    -c "mdw $COUNT 1" -c "mdw $RES_H 1" -c "mdw $DONE 1" -c "mdw $RES_ST 1" \
    -c "shutdown" 2>&1 | grep -E "^0x200004"   # NOT ^0x2000048 — that silently drops 0x20000490
}

echo
printf "%-42s %-11s %-9s %-9s %s\n" "LEG (only the ADMIT word differs)" "poll-task#" "handle" "state" "completion"
rc=0
# handle and exec_state are ASSERTED, not just printed. They were displayed only, so the
# 00000001 that localises the fault to poll-round rather than admit was eyeballed — a
# regression breaking exec_admit would still have printed OK on the control leg. Found by
# clean-room verification. exec_state==1 is gale's OWN view and matches the wasmtime
# reference's "admitted task starts in state 1"; on the no-admit leg both words must remain
# the reset poison, because neither call is made.
for leg in "1|task admitted (baseline)|ge1|00000000|00000001" \
           "0|no admit (negative control)|eq0|deadbeef|deadbeef"; do
  IFS='|' read -r flag label want wanth wantst <<EOF
$leg
EOF
  out=$(run_leg "$flag")
  cnt=$(echo "$out" | grep "^0x20000484" | awk '{print $2}')
  h=$(echo "$out"   | grep "^0x20000488" | awk '{print $2}')
  d=$(echo "$out"   | grep "^0x2000048c" | awk '{print $2}')
  st=$(echo "$out"  | grep "^0x20000490" | awk '{print $2}')
  ok="OK"
  # The completion marker is checked FIRST: without it, "poll-task was never called"
  # and "the CPU never resumed" are the same reading, and the control would be vacuous.
  [ "$d" = "c0ffee00" ] || { ok="*** DID NOT COMPLETE ($d) ***"; rc=1; }
  if [ -n "$cnt" ] && [ "$d" = "c0ffee00" ]; then
    n=$((0x$cnt))
    case "$want" in
      ge1) [ "$n" -ge 1 ] || { ok="*** poll-task NOT reached (count $n) ***"; rc=1; } ;;
      eq0) [ "$n" -eq 0 ] || { ok="*** poll-task reached $n time(s) WITHOUT an admit ***"; rc=1; } ;;
    esac
  elif [ -z "$cnt" ]; then ok="*** no count read ***"; rc=1; fi
  [ "$h"  = "$wanth"  ] || { ok="$ok *** handle $h, want $wanth ***"; rc=1; }
  [ "$st" = "$wantst" ] || { ok="$ok *** exec_state ${st:-<none>}, want $wantst ***"; rc=1; }
  printf "  %-40s %-11s %-9s %-9s %-9s %s\n" "$label" "${cnt:-<none>}" "$h" "${st:-<none>}" "$d" "$ok"
done
echo
[ $rc -eq 0 ] && echo "PASS — gale-nano's dispatch loop ran on silicon and reached the embedder only when a task was admitted." || echo "FAIL"
exit $rc
