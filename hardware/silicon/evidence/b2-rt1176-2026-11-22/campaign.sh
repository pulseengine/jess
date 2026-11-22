#!/usr/bin/env bash
# B2 (TEST-PIX-039): 3 images x 20 load-to-RAM attempts on the real RT1176, round-robin.
# Run ON THE PROBE HOST:  campaign.sh <bench-dir> <this-evidence-dir> <out-dir>
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
N="${N:-20}"; IMAGES="${IMAGES:-ekf ekf_nc1 ekf_n15}"
WD="${WD:-/usr/local/bin/with-device}"
mkdir -p "$OUT"; T="$OUT/attempts.tsv"
[ -f "$T" ] || printf 'round\timage\trc\toutcome\tutc\n' > "$T"
for i in $(seq "${START:-1}" "$N"); do
  for img in $IMAGES; do
    cap="$OUT/$img.a$i.words"; log="$OUT/$img.a$i.log"; rm -f "$cap"
    "$WD" pixhawk-6xrt mcu-link --wait 900 \
      --purpose "jess B2 TEST-PIX-039 round $i $img: load-to-RAM only, no flash" -- \
      env READ=ekf ATTEMPTS=1 CAPTURE="$cap" WD="$WD" \
      "$BENCH/on-target-run.sh" "$EV/images/$img.elf" --restore > "$log" 2>&1
    rc=$?
    if [ -f "$cap" ]; then
      if [ "$(tail -1 "$cap")" = "$(cat "$EV/expect/$img.words")" ]; then o=match; else o=WRONG; fi
    elif grep -qE 'bytes written at address 0x00000000' "$log"; then o=no-run
    else o=refused; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$img" "$rc" "$o" "$(date -u +%FT%TZ)" | tee -a "$T"
    case "$o" in
      WRONG)   echo "STOP: wrong word on $img round $i (see $cap)"; exit 1 ;;
      refused) echo "STOP: refused before load on $img round $i (see $log)"; exit 2 ;;
    esac
    lsusb -d 3643:001d 2>/dev/null | grep -q 'PX4 FMU' \
      || { echo "STOP: PX4 not enumerated after $img round $i"; exit 3; }
  done
done
echo "done: $(($(wc -l < "$T") - 1)) attempts recorded in $T"
