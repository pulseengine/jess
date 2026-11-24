#!/usr/bin/env bash
# Run a jess image on the REAL RT1176 by load-to-RAM over SWD, and read its parked results.
#
# WHY THIS IS A SCRIPT AND NOT A SEQUENCE OF COMMANDS. Two reasons, both learned the hard way.
#
# 1. THE INTERLOCK MUST BE CHECKED, NOT REMEMBERED. with-device's own source says it: "on
#    2026-09-05 jess broke it five times in one session — every time while chasing a bug, which is
#    exactly when attention is elsewhere. A rule that fails under pressure needs to be checkable
#    rather than promised." Every vehicle action in the 2026-10-01 session WAS wrapped, but it was
#    wrapped by hand each time. This script asserts its own precondition with
#    `with-device --require-claim` and REFUSES to run outside a claim, so the rule cannot be
#    forgotten under pressure.
#
# 2. THE PROCEDURE HAS NON-OBVIOUS STEPS THAT COST A SESSION TO FIND. They are encoded here so
#    nobody rediscovers them:
#      VTOR. PX4 sets VTOR = 0x00210000. jess images put their vector table at 0x00000000 and
#        never write VTOR, because in Renode VTOR defaults to 0 and the image's table is therefore
#        already in use. On silicon, any exception vectors into PX4's handlers, which RESET THE
#        BOARD — the first attempt died as "external reset detected" with PX4 back at PC
#        0x00223104. Writing VTOR=0 before resume is mandatory and is invisible in emulation.
#      THE SENTINEL IS THE ONLY PROOF OF COMPLETION. A run that did not finish parks all zeros,
#        which is NOT a result. This script refuses to print results without the sentinel.
#      THE RUN WAS INTERMITTENT WITHOUT PRIMASK. Some attempts died with
#        "external reset detected" and PX4 back at PC 0x00223104, EVEN WITH VTOR SET, parking all
#        zeros with no sentinel. A watchdog was refuted (WDOG1/2 WDE clear, RTWDOG3 EN clear).
#        THE CAUSE WAS FOUND 2026-11-24 (hardware/silicon/evidence/lockup-rt1176-2026-11-24/):
#        SRC_SRSR read 0x10000004, an M7 LOCKUP, from the first 50 ms after resume. PX4 is halted,
#        not reset, so an interrupt it enabled can be pending at resume, and the jess image's
#        2-word vector table has no valid handler for it or for the fault that follows.
#        PRIMASK=1 before resume gave 10 of 10 complete and correct runs with SRSR 0, against
#        2 of 60 in B2. This script therefore sets `reg primask 1` before `resume` (below).
#        Which interrupt it is was not identified. The bounded retry stays as a backstop.
#      A CORE-ONLY RESET DOES NOT RESTORE PX4. After `reset run` on the core alone the FMU did not
#        re-enumerate at all. Restoring needs nRST (Pixhawk Debug Full pin 9), after which the
#        board comes up as "PX4 BL" and chains to "PX4 FMU" in ~18 s.
#
# WHAT IT DOES NOT DO: write flash, enter ISP, or program fuses. Load-to-RAM only touches ITCM and
# DTCM, which the boot ROM repopulates from flash on reset. Fuse programming is the one
# irreversible operation on this part (SEC_CONFIG, SRK hash, JTAG_DISABLE) and nothing here goes
# near it.
#
# Usage, ON THE HOST THAT HAS THE PROBE, inside a claim:
#   with-device pixhawk-6xrt mcu-link --purpose '...' -- on-target-run.sh <image.elf> [--restore]
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
WD="${WD:-$D/with-device}"
# BOTH CHANNELS, because this script drives both (AFD-136). It asserted only `pixhawk-6xrt` while
# running openocd through the MCU-Link and reading the board's tty for the pre-flight gate. The
# registry on fourpi.local states the rule this violated, in its own words: "Distinct from
# mcu-link, which is the SWD path to the same silicon — holding one does not imply the other, and
# a flash-then-observe sequence needs both." This IS a flash-then-observe sequence.
# The separation of the two names is DELIBERATE and stays: the USB console and the SWD port are
# different resources, and a console reader does not race a probe user. But they are the same
# silicon — halting the M7 stops the firmware that produces the console — so anything touching
# both needs both. An agent holding only `mcu-link` satisfied no assertion here and was free to
# attach openocd mid-load; that is gale#397's shape aimed at the vehicle.
DEVS="${DEVS:-pixhawk-6xrt mcu-link}"
DEV="${DEV:-}"            # back-compat: DEV=x is honoured as a single-device DEVS
[ -n "$DEV" ] && DEVS="$DEV"
# The FMU console by its stable name. /dev/ttyACMn numbering moves when the host reboots: on
# 2026-11-22 ttyACM0 became an unrelated USB radio and the gate read the wrong device.
TTY="${TTY:-/dev/serial/by-id/usb-Dronecode_Project__Inc._PX4_FMU_v6XRT.x_0-if00}"
OOCD_CFG="${OOCD_CFG:-$D/openocd/rt1176-swd.cfg}"
SRST_CFG="${SRST_CFG:-$D/openocd/rt1176-srst.cfg}"
SETTLE="${SETTLE:-3}"
RUNFOR_MS="${RUNFOR_MS:-3000}"
# WHICH PARKING LAYOUT TO READ. The load procedure is the same for every jess image; what differs
# is where the image parks its results and which word proves it finished.
#   chain (default)  the cascade chain image: 5 words at 0x20011000, 6 at 0x20011100, sentinel
#                    1e55d09e as the 6th CHAIN word.
#   ekf              the estimator image (cascade-invoke/boot-ekf.S): 31 words at 0x20011400,
#                    sentinel 1e55e4f0 as word 30. This script does NOT judge those words; it
#                    writes them to $CAPTURE, bound to the ELF's sha256, and
#                    run-ekf-oracle.sh WORDS_DIR=... judges them against wasmtime with the same
#                    code that judges the emulator.
READ="${READ:-chain}"
case "$READ" in
  chain) SENTINEL="1e55d09e" ;;
  ekf)   SENTINEL="1e55e4f0"; EKF_BASE=0x20011400; EKF_WORDS=31 ;;
  *)     printf 'FAIL: READ=%s is not one of: chain ekf\n' "$READ" >&2; exit 1 ;;
esac

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ $# -ge 1 ] || fail "usage: [READ=chain|ekf] [CAPTURE=<file>] on-target-run.sh <image.elf> [--restore]"
ELF="$1"; shift
RESTORE=0; for a in "$@"; do [ "$a" = "--restore" ] && RESTORE=1; done
[ -f "$ELF" ] || fail "image not found: $ELF"
if [ "$READ" = "ekf" ]; then
  CAPTURE="${CAPTURE:-$(basename "$ELF" .elf).words}"
  # Remove a previous capture FIRST, so a run that fails below cannot leave an older run's words
  # under this name for the oracle to read as this run's.
  rm -f "$CAPTURE"
  ELF_SHA="$( (sha256sum "$ELF" 2>/dev/null || shasum -a 256 "$ELF") | awk '{print $1}')"
  [ -n "$ELF_SHA" ] || fail "could not hash $ELF"
fi

# ── (1) THE INTERLOCK, ASSERTED NOT ASSUMED ───────────────────────────────────────────────────
# A script that touches hardware without a claim races another agent silently. This makes that
# impossible rather than unlikely.
[ -x "$WD" ] || fail "with-device not found at $WD — refusing to touch hardware without the
   interlock. Set WD=<path>."
# EVERY device in DEVS, checked individually so the message names the one that is missing. A
# single combined check would say "not under a claim" when the operator holds one of the two,
# which is the confusing half of this defect.
for d in $DEVS; do
  "$WD" --require-claim "$d" \
    || fail "NOT RUNNING UNDER A '$d' CLAIM. This script needs ALL of: $DEVS
     $WD $DEVS --purpose '<why>' -- $0 $ELF $*
   Refusing: two agents on one board each capture a silent subset, which is
   indistinguishable from a flaky link (gale#356, measured on this Pixhawk). And the SWD
   path is a SEPARATE claim from the USB console — holding one does not cover the other
   (AFD-136), while halting the M7 through the probe stops the firmware the console comes
   from, so this sequence needs both."
done
echo "   claims asserted: $DEVS (held: ${WITH_DEVICE_CLAIM:-<unset>})"

# ── (2) THE SAFETY GATE ───────────────────────────────────────────────────────────────────────
# Halting the M7 stops the flight controller. On a quadrotor that is catastrophic if armed, so
# this is FAIL-CLOSED: "could not determine" blocks exactly like "armed".
if [ -x "$D/preflight-disarmed.py" ] || [ -f "$D/preflight-disarmed.py" ]; then
  # BOUNDED. The gate blocked ~5 min in the kernel's set_termios on 2026-11-22 and needed a kill.
  # "Could not determine" must exit, not hang: a timeout refuses exactly like any other refusal.
  timeout 30 python3 "$D/preflight-disarmed.py" "$TTY" --lib "$D" \
    || fail "pre-flight gate refused (or did not answer within 30 s) — not proceeding"
else
  fail "preflight-disarmed.py missing next to this script — refusing to halt the M7 without
   proving the vehicle is disarmed"
fi

# ── (3) LOAD AND RUN ──────────────────────────────────────────────────────────────────────────
echo "   settling ${SETTLE}s before the first halt (see the note on reset state)"
sleep "$SETTLE"

# WHY A RETRY IS LEGITIMATE HERE AND USUALLY IS NOT. "Run it again until it passes" is how a
# flaky gate gets laundered into a green one. It is admissible only because the two outcomes are
# UNAMBIGUOUSLY DIFFERENT and only one of them is retried:
#     no sentinel + all-zero parking  ->  the image DID NOT RUN. Nothing was measured. Retryable.
#     sentinel present                ->  the image ran and these ARE its results, right or wrong.
#                                         NEVER retried, whatever the values.
# So this never retries a wrong answer into a right one; it only retries a non-event. The attempt
# count is reported so a reader can see the procedure is not yet reliable (the cause is unknown —
# see the note at the top), rather than having that hidden by a clean-looking pass.
ATTEMPTS="${ATTEMPTS:-3}"
# --restore RUNS ON EVERY EXIT FROM HERE ON, not only after a clean read. Measured 2026-11-17: the
# init-skipped ekf control locked the M7 up (double fault), the readout failed, the script exited
# through `fail`, and PX4 was left down although --restore was given. From this point the board
# may hold jess's image, so a failure must not skip the restore. Before this point nothing was
# loaded and the board is left alone.
restore_px4() {
  echo "   === restoring PX4 via nRST (a core-only reset is NOT sufficient) ==="
  if [ ! -f "$SRST_CFG" ]; then
    echo "FAIL: no SRST config at $SRST_CFG — cannot restore; the board is left holding jess's
   image in RAM. Power-cycle it." >&2; return 1
  fi
  timeout 45 openocd -f "$SRST_CFG" -c "init" -c "reset run" -c "shutdown" >/dev/null 2>&1
  for i in $(seq 1 12); do
    sleep 5
    # The KERNEL's product string, not lsusb's. The bootloader and the app share 3643:001d, and
    # lsusb prints its id-database name for both, so `lsusb | grep "PX4 FMU"` matched the
    # bootloader and reported the app up while it was not (B2, 2026-11-22: the next gate got EIO
    # when the bootloader dropped off). The kernel says "PX4 BL FMU v6XRT.x" vs "PX4 FMU v6XRT.x".
    if grep -qx 'PX4 FMU v6XRT.x' /sys/bus/usb/devices/*/product 2>/dev/null; then
      echo "   PX4 app back up after ~$((i*5))s"; return 0
    fi
  done
  echo "FAIL: PX4 did NOT come back within 60s. Check lsusb: it may be sitting in the bootloader
   ('PX4 BL'), which chains to the app on its own, or it may need a power cycle." >&2
  return 1
}
OUT="$(mktemp)"
trap 'rc=$?; rm -f "$OUT"; if [ "$RESTORE" = "1" ]; then restore_px4 || rc=1; fi; exit $rc' EXIT
attempt=0
if [ "$READ" = "ekf" ]; then
  RD=( -c "mdw $EKF_BASE $EKF_WORDS" )
else
  RD=( -c "mdw 0x20011000 5" -c "mdw 0x20011100 6" )
fi
while : ; do
attempt=$((attempt+1))
timeout 120 openocd -f "$OOCD_CFG" \
  -c "init" -c "halt" \
  -c "load_image $ELF" \
  -c "mww 0xE000ED08 0x00000000" \
  -c "reg sp 0x20040000" -c "reg pc 0x8" \
  -c "reg primask 1" -c "reg primask" \
  -c "resume" -c "sleep $RUNFOR_MS" -c "halt" \
  -c "reg pc" \
  "${RD[@]}" \
  -c "shutdown" > "$OUT" 2>&1
rc=$?

grep -qE '[0-9]+ bytes written at address 0x00000000' "$OUT" \
  || { sed 's/^/     /' "$OUT" >&2; fail "the image never loaded — 'could not run', not a result"; }
# PRIMASK must read back as 1 before resume (the lockup fix, see the header). The read-back is
# openocd's report from the core, so a missing or wrong line means the fix did not reach it: refuse.
grep -qE '^primask \(/[0-9]+\): 0x0*1[[:space:]]*$' "$OUT" \
  || { sed 's/^/     /' "$OUT" >&2; fail "PRIMASK did not read back as 1 before resume — refusing (lockup fix not applied)"; }

# Retry ONLY the non-event: a reset with no sentinel means nothing was measured.
if grep -q 'external reset detected' "$OUT" && ! grep -q "$SENTINEL" "$OUT"; then
  echo "   attempt $attempt/$ATTEMPTS: board reset mid-run, no sentinel -> the image did not run."
  if [ "$attempt" -lt "$ATTEMPTS" ]; then
    echo "   retrying after a ${SETTLE}s settle (cause UNKNOWN; a watchdog is refuted by measurement)"
    sleep "$SETTLE"; continue
  fi
  sed 's/^/     /' "$OUT" >&2
  fail "the board RESET during every one of $ATTEMPTS attempts, each time with no sentinel, so
   nothing was measured. This is 'could not run', NOT a result about the image. If VTOR was not
   set to 0 see the note at the top; it IS set here, and the remaining cause is unknown."
fi
break
done
[ "$attempt" -gt 1 ] && echo "   NOTE: attempt $attempt of $ATTEMPTS did not reset mid-run (its result is judged below) — the procedure is
   NOT yet reliable and the cause is unestablished. Do not read a single clean run as stability."

PC="$(grep -oE '^pc \(/32\): 0x[0-9a-f]+' "$OUT" | tail -1 | awk '{print $3}')"

if [ "$READ" = "ekf" ]; then
  # openocd prints `mdw` as lines of up to 8 words, each prefixed by its address. Take every word
  # on the lines in [EKF_BASE, EKF_BASE + 4*EKF_WORDS) and require EXACTLY EKF_WORDS of them.
  W=( $(grep -oE '^0x200114[0-9a-f]{2}: ([0-9a-f]{8} ?)+' "$OUT" | cut -d: -f2-) )
  [ "${#W[@]}" -eq "$EKF_WORDS" ] \
    || { sed 's/^/     /' "$OUT" >&2; fail "read ${#W[@]} words from $EKF_BASE, not $EKF_WORDS — could not read the parking area"; }
  if [ "${W[30]}" != "$SENTINEL" ]; then
    echo "   WORDS ${W[*]}"
    fail "completion sentinel is '${W[30]}', not $SENTINEL — the image DID NOT FINISH, so these
   words are not a result. No capture written."
  fi
  {
    echo "sha256 $ELF_SHA"
    echo "origin rt1176-silicon swd-load-to-ram attempt=$attempt/$ATTEMPTS pc=$PC"
    echo "${W[*]}"
  } > "$CAPTURE"
  echo "   halted at PC $PC"
  echo "   sentinel $SENTINEL present — the image ran to completion"
  echo "   $EKF_WORDS words from $EKF_BASE written to $CAPTURE (bound to sha256 $ELF_SHA)"
  echo "   judge them with: WORDS_DIR=<dir> hardware/renode/cascade-invoke/run-ekf-oracle.sh"
else
RES="$(grep -oE '^0x20011000: ([0-9a-f]{8} ?){5}' "$OUT" | head -1 | cut -d: -f2-)"
CHN="$(grep -oE '^0x20011100: ([0-9a-f]{8} ?){6}' "$OUT" | head -1 | cut -d: -f2-)"
[ -n "$RES" ] && [ -n "$CHN" ] || { sed 's/^/     /' "$OUT" >&2; fail "could not read the parking area"; }

# ── (4) THE SENTINEL IS THE ONLY PROOF OF COMPLETION ──────────────────────────────────────────
got_sent="$(printf '%s\n' "$CHN" | awk '{print $6}')"
if [ "$got_sent" != "$SENTINEL" ]; then
  echo "   RESULT $RES"
  echo "   CHAIN  $CHN"
  fail "completion sentinel is '$got_sent', not $SENTINEL — the image DID NOT FINISH, so these
   words are not a result. All-zero parking words mean 'did not run', never 'the answer is zero'.
   (A run immediately after a board reset can need a longer SETTLE.)"
fi

echo "   halted at PC $PC (0x52 = the spin loop at the end of _reset)"
echo "   RESULT 0x20011000 (ret-offset + 4 torque words): $RES"
echo "   CHAIN  0x20011100 (pwm-offset + 4 pwm + sentinel): $CHN"
echo "   sentinel $SENTINEL present — the image ran to completion"
fi

# ── (5) RESTORE, ONLY IF ASKED ────────────────────────────────────────────────────────────────
# Not the default: a caller running several images back to back should not pay a ~20 s reboot
# between them. But leaving the vehicle with jess's image in RAM is not an end state. With
# --restore it runs from the EXIT trap above, so it also runs when a step after the load fails.
if [ "$RESTORE" != "1" ]; then
  echo "   NOTE: jess's image is still in RAM and PX4 is NOT running. Re-run with --restore, or
   reset the board, before leaving it."
fi
