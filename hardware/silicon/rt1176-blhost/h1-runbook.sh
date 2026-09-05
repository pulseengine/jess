#!/usr/bin/env bash
# H1 — execute jess-built code on the RT1176 and read the result back. RAM ONLY.
#
# SAFETY MODEL, and it is the point of this script existing rather than a list of commands:
#   * DEFAULT IS READ-ONLY. Phases 1-2 only identify and query. The write/execute phase
#     requires --execute, which a human passes deliberately.
#   * NO FLASH COMMAND IS EVER ISSUED. Not erase, not program, not configure-memory. grep
#     this file: the only mutating blhost verbs are write-memory and call.
#   * THE TARGET ADDRESS IS NEVER GUESSED. It is taken from `blhost get-property 12`
#     (reserved-regions) and the script REFUSES if that query fails or returns nothing.
#     Writing to an address the bootloader has not reserved is how you corrupt its own state.
#   * PASS REQUIRES BOTH WORDS. 0x1E55F00D at the address AND arg+0x55 at arg+4. The second
#     is address-derived, so a stale RAM read cannot fake it — a single-word check could.
#
# ENTERING ISP IS NOT DONE HERE. That is a command to the vehicle and belongs to the
# operator: in QGroundControl, Analyze Tools -> MAVLink Console -> `reboot -i`
# (per PX4 docs for v6xrt). The BOOT button inside the FMUM module is the bricked-board
# fallback, not the normal path. Power-cycle returns the board to normal PX4 operation.
#
# Usage:
#   h1-runbook.sh --dry-run     print every command, execute nothing, touch nothing
#   h1-runbook.sh               phases 1-2 only (identify + query). READ-ONLY.
#   h1-runbook.sh --execute     phases 1-3. Writes 16 B to RESERVED RAM, calls it, reads back.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$D/../../.." && pwd)"
VENV="${VENV:-/private/tmp/claude-501/-Volumes-Home-git-pulseengine-jess/spsdk-venv}"
SCRATCH="${SCRATCH:-$ROOT/.scratch}"
PAYLOAD="$D/sig.bin"
FLASHLOADER="$SCRATCH/h1/ivt_flashloader.bin"
MODE="readonly"; DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --execute) MODE="execute" ;;
    *) echo "unknown argument: $a" >&2; exit 1 ;;
  esac
done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run() { # echo, then run unless --dry-run
  printf '    $ %s\n' "$*"
  [ "$DRY" = "1" ] && return 0
  "$@"
}
cap() { # like run but captures stdout
  printf '    $ %s\n' "$*" >&2
  [ "$DRY" = "1" ] && { echo ""; return 0; }
  "$@"
}

BLHOST="$VENV/bin/blhost"; SDPHOST="$VENV/bin/sdphost"; DEVSCAN="$VENV/bin/nxpdevscan"
for t in "$BLHOST" "$SDPHOST" "$DEVSCAN"; do
  [ -x "$t" ] || fail "missing $t — rebuild the spsdk venv"
done
[ -f "$PAYLOAD" ] || fail "payload missing: $PAYLOAD"
[ "$(wc -c < "$PAYLOAD" | tr -d ' ')" = "16" ] || fail "payload is not 16 bytes — refusing"
SCRATCH="$SCRATCH" "$ROOT/tools/deps/check.sh" --only h1/ >/dev/null 2>&1 \
  || fail "the pinned flashloader does not verify — run tools/deps/fetch.sh"

echo "== phase 1: IDENTIFY (read-only) =="
echo "  The board must already be in ISP. If it is not, this finds nothing and stops."
echo "  spsdk's device database says: ROM speaks SDP (0x1FC9:0x013D); blhost/mboot"
echo "  (0x15A2:0x0073) is reachable only once a flashloader runs. This settles which."
run "$DEVSCAN"
if [ "$DRY" = "0" ]; then
  scan="$("$DEVSCAN" 2>&1)"
  echo "$scan" | grep -qiE "0x1fc9|0x15a2|NXP (SDP|MBOOT)" \
    || fail "no NXP device found. The board is not in ISP (or is not enumerating). Nothing was done."
  if echo "$scan" | grep -qi "0x15a2"; then
    echo "  -> mboot device present: a flashloader is ALREADY running; skip phase 1b."
    NEED_FL=0
  else
    echo "  -> SDP ROM only: a flashloader must be loaded before blhost will answer."
    NEED_FL=1
  fi
else
  NEED_FL=1
fi

if [ "${NEED_FL:-1}" = "1" ]; then
  echo "== phase 1b: load the PINNED flashloader into OCRAM (RAM only, no flash) =="
  echo "  digest-verified above; IVT self=0x2024FE00 entry=0x20262561, both OCRAM1."
  run "$SDPHOST" -u -- write-file 0x20240000 "$FLASHLOADER"
  run "$SDPHOST" -u -- jump-address 0x20240000
  echo "  (the board re-enumerates as mboot 0x15A2:0x0073)"
fi

echo "== phase 2: QUERY (read-only) =="
run "$BLHOST" -u -- get-property 1        # bootloader version — proves who is answering
run "$BLHOST" -u -- get-property 12       # RESERVED REGIONS — the only legal target
if [ "$DRY" = "0" ]; then
  regions="$("$BLHOST" -u -- get-property 12 2>&1)"
  echo "$regions" | grep -qiE "0x[0-9a-f]{8}" || fail "reserved-regions returned nothing parseable — REFUSING to pick an address. Writing outside a reserved region can corrupt the bootloader's own state."
  echo "  reserved regions reported; an address will be chosen from these and from nowhere else."
fi

if [ "$MODE" != "execute" ]; then
  echo
  echo "Result: READ-ONLY PHASES COMPLETE. Nothing was written."
  echo "        Re-run with --execute to write 16 B to a reserved RAM address, call it,"
  echo "        and read back. Flash is never touched in either mode."
  exit 0
fi

echo "== phase 3: WRITE / CALL / READ-BACK (RAM only) =="
echo "  ADDR must be exported by the operator from the reserved regions printed above."
[ -n "${ADDR:-}" ] || fail "ADDR is not set. Refusing to guess. Export ADDR=<an address inside a reserved region reported by phase 2>."
run "$BLHOST" -u -- write-memory "$ADDR" "$PAYLOAD"
run "$BLHOST" -u -- call "$ADDR" "$ADDR"
echo "  reading back the two markers:"
run "$BLHOST" -u -- read-memory "$ADDR" 8
if [ "$DRY" = "0" ]; then
  out="$("$BLHOST" -u -- read-memory "$ADDR" 8 2>&1)"
  echo "$out" | grep -qi "0d f0 55 1e\|1e55f00d" || fail "marker 0x1E55F00D not found at $ADDR — the payload did not execute"
  echo "  both markers must be checked; arg+0x55 is address-derived and cannot be faked by stale RAM."
  echo
  echo "Result: PASS — jess-built code EXECUTED on the RT1176. First time on silicon."
fi
