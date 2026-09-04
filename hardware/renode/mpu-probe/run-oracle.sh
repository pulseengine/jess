#!/usr/bin/env bash
# TEST-PIX-036 — CHARACTERIZE whether the emulated RT1176 Cortex-M7 ENFORCES the MPU.
#
# WHY THIS EXISTS. gale#348: the verified MPU primitive cannot ship as a wasm artifact
# because enforcement is a PRIVILEGED PPB REGISTER WRITE (MPU_RBAR/MPU_RASR at 0xE000ED9C).
# If gale ships it, jess gets the verified region-table computation and THE REGISTER WRITE
# BECOMES JESS'S OBLIGATION. Before building to that, jess needs to know whether the
# obligation can be VALIDATED in emulation at all.
#
# It cannot, and the way it fails is the trap:
#   MPU_TYPE reads 0x00000800  -> 8 regions advertised
#   MPU_CTRL reads back 0x1    -> MPU enabled, PRIVDEFENA=0 (background disabled)
#   MPU_RBAR/RASR read back EXACTLY as written
#   ...and an access OUTSIDE the only region still SUCCEEDS.
# So the register file is modelled and the enforcement is not. Any test that programmed the
# MPU and checked the registers would report success while nothing was enforced — a vacuous
# pass of exactly the kind this campaign keeps finding.
#
# THIS IS A CHARACTERIZATION TEST, NOT A GATE ON JESS'S CODE. It asserts the CURRENT
# behaviour of the emulator, so that if Renode ever gains MPU enforcement it FAILS LOUDLY
# and jess learns that the obligation became testable. A silent pass either way would tell
# us nothing.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$D/../../.." && pwd)"
RENODE="${RENODE:-/Users/r/renode-1.16.1/Contents/MacOS/renode}"
OUT="${OUT:-$ROOT/.scratch/mpu-probe}"; mkdir -p "$OUT"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -x "$RENODE" ] || { echo "SKIP: renode not at $RENODE" >&2; exit 2; }
command -v arm-none-eabi-gcc >/dev/null || fail "arm-none-eabi-gcc not on PATH"

arm-none-eabi-gcc -c -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard "$D/mpu.S" -o "$OUT/mpu.o" || fail "assemble"
arm-none-eabi-ld -T "$D/link.ld" "$OUT/mpu.o" -o "$OUT/mpu.elf" || fail "link"

RESCDIR="$(mktemp -d)"; trap 'rm -rf "$RESCDIR"' EXIT
cat > "$RESCDIR/p.resc" <<EOF
using sysbus
mach create "mpuprobe"
machine LoadPlatformDescription @hardware/renode/pixhawk6xrt.repl
sysbus LoadELF @$OUT/mpu.elf
emulation RunFor "0.05"
pause
echo "B"
sysbus ReadDoubleWord 0x20030000
sysbus ReadDoubleWord 0x20030004
sysbus ReadDoubleWord 0x20030008
sysbus ReadDoubleWord 0x2003000C
sysbus ReadDoubleWord 0x20030010
sysbus ReadDoubleWord 0xE000ED94
sysbus ReadDoubleWord 0xE000EDA0
echo "E"
EOF
# Raw output to a FILE first, then parse. A one-shot pipeline here silently produced zero
# words and the failure told me nothing about which stage lost them; the log is worth keeping.
( cd "$ROOT" && "$RENODE" --console --disable-xwt -e "include @$RESCDIR/p.resc
quit" 2>&1 ) | perl -pe 's/\e\[[0-9;]*m//g' > "$OUT/probe.log" 2>&1
# Renode terminates lines with \r\r\n, so the markers are "\rB\r\r\n" and a bare /^B$/
# never matches — the sibling oracles only avoid this because their python parser rstrips.
# An unstripped parse here silently yielded ZERO words while the log plainly held seven.
W=( $(tr -d '\r' < "$OUT/probe.log" | awk '/^B$/{f=1;next} /^E$/{f=0} f' | grep -E '^0x') )
[ "${#W[@]}" -eq 7 ] || fail "expected 7 words, got ${#W[@]} (${W[*]:-none})"

TYPE="${W[0]}"; INSIDE="${W[1]}"; OUTSIDE="${W[2]}"; CFSR="${W[3]}"; FAULT="${W[4]}"
CTRL="${W[5]}"; RASR="${W[6]}"
echo "  MPU_TYPE      $TYPE   (DREGION!=0 means the model advertises an MPU)"
echo "  MPU_CTRL      $CTRL   (0x1 = enabled, background region DISABLED)"
echo "  MPU_RASR      $RASR   (as written: AP=3, 32KB, ENABLE)"
echo "  inside write  $INSIDE"
echo "  outside write $OUTSIDE"
echo "  CFSR          $CFSR"
echo "  fault marker  $FAULT"

# 1. The model must advertise an MPU and accept its configuration, or the probe is
#    measuring an absent register file rather than absent enforcement — different facts.
[ "$TYPE" != "0x00000000" ] || fail "MPU_TYPE reports ZERO regions — this model has no MPU register file at all, so the probe cannot distinguish 'not enforced' from 'not present'"
[ "$CTRL" = "0x00000001" ] || fail "MPU_CTRL did not read back as enabled (got $CTRL) — configuration did not take, so a non-fault proves nothing"
[ "$RASR" = "0x0300001D" ] || fail "MPU_RASR did not read back as written (got $RASR) — configuration did not take"
[ "$INSIDE" = "0x1111AAAA" ] || fail "the INSIDE-region write did not land ($INSIDE) — the probe itself is broken"
echo "   register file is modelled and the configuration took"

# 2. The characterization. Exactly one of these is true.
if [ "$FAULT" = "0x1E55FA17" ]; then
  echo "   outside-region access FAULTED (CFSR $CFSR)"
  fail "MPU ENFORCEMENT IS NOW PRESENT in this Renode build. That is GOOD NEWS and a CHANGE: the gale#348 embedder obligation just became testable in emulation. Update TEST-PIX-036 and AFD-076, then re-enable the enforcement leg."
fi
[ "$OUTSIDE" = "0x2222BBBB" ] || fail "the outside write neither faulted nor landed (got $OUTSIDE) — unexpected third behaviour, investigate before trusting any MPU result here"
[ "$CFSR" = "0x00000000" ] || fail "no fault was taken yet CFSR is $CFSR — inconsistent, investigate"

echo
echo "Result: PASS (characterization) — Renode models the Cortex-M7 MPU REGISTER FILE but does"
echo "        NOT ENFORCE regions: MPU enabled with the background region disabled, and an"
echo "        access outside the only region still succeeded. jess CANNOT validate the gale#348"
echo "        register-write obligation in emulation; that leg needs silicon."
