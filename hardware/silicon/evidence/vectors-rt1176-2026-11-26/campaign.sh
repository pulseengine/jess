#!/usr/bin/env bash
# The vector-table run (PREREGISTRATION.md here). B2's campaign.sh (../b2-rt1176-2026-11-22/) with
# three changes: PRIMASK_AT_RESUME and IMAGES are REQUIRED, so each arm names its condition; the
# value is passed to on-target-run.sh explicitly; and each attempt also records the exception-log
# line and whether the log shows "external reset detected".
# Run ON THE PROBE HOST:  PRIMASK_AT_RESUME=0|1 IMAGES=... N=... campaign.sh <bench-dir> <this-evidence-dir> <out-dir>
#
# Every attempt is its own with-device claim of BOTH pixhawk-6xrt and mcu-link (AFD-136), with
# ATTEMPTS=1 so on-target-run.sh never retries: each load attempt is counted once. --restore
# brings PX4 back after every attempt, because the next attempt's disarmed gate reads PX4.
# Nothing here writes flash.
#
# Per attempt the outcome is one of:
#   match     capture written and its 31 words equal expect/<image>.words byte for byte
#   WRONG     capture written (the sentinel is present) and a word differs. Stops the campaign.
#   no-run    no capture: the image did not finish. Counted against the completion rate.
#   refused   the gate or the claim refused before loading. Not a load attempt; stops the run.
# The campaign also stops if PX4 is not enumerated after an attempt.
set -uo pipefail
BENCH="${1:?bench dir}"; EV="${2:?evidence dir}"; OUT="${3:?out dir}"
N="${N:?N}"; IMAGES="${IMAGES:?IMAGES}"
PRIMASK_AT_RESUME="${PRIMASK_AT_RESUME:?PRIMASK_AT_RESUME must be 0 or 1}"
WD="${WD:-/usr/local/bin/with-device}"
RUNFOR_MS="${RUNFOR_MS:-3000}"   # on-target-run.sh's own default; B2b sets 200
# The FMU console by its stable name. /dev/ttyACMn numbering moves when the host reboots: on
# 2026-11-22 ttyACM0 became an unrelated radio dongle and the gate read the wrong device.
TTY="${TTY:-/dev/serial/by-id/usb-Dronecode_Project__Inc._PX4_FMU_v6XRT.x_0-if00}"
[ -e "$TTY" ] || { echo "STOP: FMU console $TTY not present"; exit 2; }
# Wait for the PX4 APP, not the bootloader. Both enumerate as 3643:001d and lsusb names them
# from its id database, so lsusb says "PX4 FMU" for the bootloader too. The kernel's product
# string tells them apart ("PX4 BL FMU v6XRT.x" vs "PX4 FMU v6XRT.x"). Measured 2026-11-22:
# the gate opened the port during the bootloader and got EIO when it dropped off 8 s later.
wait_app() {
  local t=0 ok=0
  while [ "$t" -lt 120 ]; do
    if grep -qx 'PX4 FMU v6XRT.x' /sys/bus/usb/devices/*/product 2>/dev/null && [ -e "$TTY" ]; then
      ok=$((ok+1)); else ok=0; fi
    [ "$ok" -ge 5 ] && return 0
    sleep 1; t=$((t+1))
  done
  return 1
}
mkdir -p "$OUT"; T="$OUT/attempts.tsv"
[ -f "$T" ] || printf 'round\timage\tprimask\trc\toutcome\treset\texceptions\tutc\n' > "$T"
for i in $(seq "${START:-1}" "$N"); do
  for img in $IMAGES; do
    wait_app || { echo "STOP: the PX4 app did not stay enumerated for 5 s within 120 s"; exit 3; }
    cap="$OUT/$img.a$i.words"; log="$OUT/$img.a$i.log"; rm -f "$cap"
    { echo "campaign: RUNFOR_MS=$RUNFOR_MS PRIMASK_AT_RESUME=$PRIMASK_AT_RESUME"
    "$WD" pixhawk-6xrt mcu-link --wait 900 \
      --purpose "jess vector-table run round $i $img primask=$PRIMASK_AT_RESUME: load-to-RAM only, no flash" -- \
      env READ=ekf ATTEMPTS=1 PRIMASK_AT_RESUME="$PRIMASK_AT_RESUME" RUNFOR_MS="$RUNFOR_MS" TTY="$TTY" CAPTURE="$cap" WD="$WD" \
      "$BENCH/on-target-run.sh" "$EV/images/$img.elf" --restore 2>&1; } > "$log"
    rc=$?
    if [ -f "$cap" ]; then
      if [ "$(tail -1 "$cap")" = "$(cat "$EV/expect/$img.words")" ]; then o=match; else o=WRONG; fi
    elif grep -qE 'bytes written at address 0x00000000' "$log"; then o=no-run
    else o=refused; fi
    if grep -q "external reset detected" "$log"; then rs=reset; else rs=-; fi
    xl="$(grep -oE "exception log: .*" "$log" | head -1 | cut -d: -f2- | sed "s/^ //")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$img" "$PRIMASK_AT_RESUME" "$rc" "$o" "$rs" "${xl:-none}" "$(date -u +%FT%TZ)" | tee -a "$T"
    case "$o" in
      WRONG)   echo "STOP: wrong word on $img round $i (see $cap)"; exit 1 ;;
      refused) echo "STOP: refused before load on $img round $i (see $log)"; exit 2 ;;
    esac
    lsusb -d 3643:001d 2>/dev/null | grep -q 'PX4 FMU' \
      || { echo "STOP: PX4 not enumerated after $img round $i"; exit 3; }
  done
done
echo "done: $(($(wc -l < "$T") - 1)) attempts recorded in $T"
