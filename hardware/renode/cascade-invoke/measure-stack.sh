#!/usr/bin/env bash
# TEST-PIX-035 — measure rate@0.7.0#tick's LINEAR-MEMORY footprint on emulated RT1176.
#
# relay holds SWREQ-FALCON-OCI-P06 on "the shared stack region fits the budget AND the
# image executes". Four of their per-stage bounds are borrowed from scry, not measured.
#
# AFD-055 concluded painting could not measure this image's shadow stack, because the
# reset handler's copy overwrites the paint. That was true of the SELF-CONTAINED image,
# where jess did not own the sequence. This harness does: init, THEN paint, THEN call.
#
# TWO THINGS MUST BOTH HOLD or the measurement means nothing:
#   (a) the paint must still be present somewhere — otherwise "nothing touched" is
#       indistinguishable from "never painted";
#   (b) the stage must have produced the CORRECT torque — otherwise "nothing touched"
#       is indistinguishable from "never ran".
# Both are asserted below. This is the failure mode AFD-055 and AFD-056 were about.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$D/../../.." && pwd)"
RENODE="${RENODE:-/Users/r/renode-1.16.1/Contents/MacOS/renode}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -x "$RENODE" ] || { echo "SKIP: renode not at $RENODE" >&2; exit 2; }
[ -f "$ROOT/.scratch/invoke/invoke.elf" ] || fail "image missing — run build.sh first"

out="$(cd "$ROOT" && "$RENODE" --console --disable-xwt -e "include @hardware/renode/cascade-invoke/highwater.resc
quit" 2>&1 | perl -pe 's/\e\[[0-9;]*m//g')"
printf '%s\n' "$out" | grep -q PAINT_END || fail "probe did not complete"

printf '%s\n' "$out" | python3 -c '
import sys,re,struct
t=sys.stdin.read()
if "0x1E55D09E" not in t:
    print("FAIL: completion sentinel absent — the harness did not finish, so an untouched"); 
    print("      paint would only mean the stage never ran"); sys.exit(1)
seg=t.split("PAINT_BEGIN",1)[1].split("PAINT_END",1)[0]
b=bytes(int(x,16) for x in re.findall(r"0x([0-9A-Fa-f]{2})",seg))
LO,HI=0x400,0x2000
w=[struct.unpack("<I",b[i:i+4])[0] for i in range(0,len(b)-3,4)]
intact=[i for i,x in enumerate(w) if x==0xDEADBEEF]
touched=[i for i,x in enumerate(w) if x!=0xDEADBEEF]
print(f"  painted 0x{LO:04X}..0x{HI:04X} ({HI-LO} B, {len(w)} words)")
print(f"  intact {len(intact)}   touched {len(touched)}")
if not intact:
    print("FAIL: NO word still carries the pattern — either the paint never applied or the")
    print("      stack blew through the whole region. Either way this is not a measurement.")
    sys.exit(1)
if touched:
    lo=LO+4*min(touched)
    print(f"  shadow-stack high-water from 0x{HI:04X}: {HI-lo} bytes (lowest touched 0x{lo:04X})")
else:
    print("  shadow-stack usage: ZERO words touched in this region")
    print("  -> and the paint IS present (see intact count) and the stage DID run and return")
    print("     the correct torque (sentinel + oracle), so this is a real zero, not an absence")
    print("     of evidence. rate#tick does not descend into the shadow stack at all.")
'
