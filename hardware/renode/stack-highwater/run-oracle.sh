#!/usr/bin/env bash
# TEST-PIX-032 — WHERE does the falcon cascade use stack on emulated RT1176 M7?
#
# relay holds SWREQ-FALCON-OCI-P06 because its criterion is "the shared stack region fits
# the target budget AND the image executes", and four of its per-stage bounds are BORROWED
# FROM SCRY rather than measured. Before measuring a high-water, this establishes WHICH
# REGION to measure — because measuring the wrong one returns a confident zero.
#
# It paints the two regions a naive stack-painting oracle would target and reports which
# execution actually touches. It does NOT report a high-water: on this image neither region
# is the answer, and printing "0 bytes used" from an untouched paint would be exactly the
# vacuous metric this campaign keeps catching in its own checkers.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$D/../../.." && pwd)"
RENODE="${RENODE:-/Users/r/renode-1.16.1/Contents/MacOS/renode}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -x "$RENODE" ] || { echo "SKIP: renode not at $RENODE (set RENODE=)" >&2; exit 2; }
[ -f "$ROOT/hardware/renode/cascade-m7/falcon-cascade-m7.elf" ] || fail "cascade ELF missing"

out="$(cd "$ROOT" && "$RENODE" --console --disable-xwt -e "include @hardware/renode/stack-highwater/probe-regions.resc
quit" 2>&1)" || true
printf '%s\n' "$out" | grep -q REGIONS_END || { printf '%s\n' "$out" | tail -20 >&2; fail "probe did not complete"; }

printf '%s\n' "$out" | python3 -c '
import sys, re
t = sys.stdin.read()
def band(a, b):
    seg = t.split(a,1)[1].split(b,1)[0]
    return [x.upper() for x in re.findall(r"0x[0-9A-Fa-f]{8}", seg)]
A = band("REGION_A", "REGION_B")
B = band("REGION_B", "REGIONS_END")
insns = int(re.search(r"INSNS\s*\n\s*(0x[0-9A-Fa-f]+)", t).group(1), 16)
pc    = re.search(r"PC\s*\n\s*(0x[0-9A-Fa-f]+)", t).group(1)
def rep(name, v, desc):
    hit = sum(1 for x in v if x != "0XDEADBEEF")
    print(f"  {name:<10} {len(v):>4} probes, {hit:>4} touched   {desc}")
    return hit
# The image MUST have run, or every "untouched" reading below is meaningless.
if insns < 100_000:
    print(f"FAIL: only {insns} instructions retired — the image did not run, so nothing")
    print("      below distinguishes an unused region from an unexecuted one."); sys.exit(1)
print(f"  image ran: {insns} instructions retired, PC {pc}")
a = rep("region A", A, "ARM hardware stack, 512 B below initial SP")
b = rep("region B", B, "linear-memory tail above the init copy")
print()
if a == 0 and b <= 1:
    print("  RESULT: NEITHER region is where this image keeps its stack.")
    print("  The ARM hardware stack is untouched, and the linear-memory tail above the")
    print("  init copy is untouched. So the wasm SHADOW STACK lives INSIDE the region the")
    print("  reset handler initialises (0x20000100 + 53,345 B) — which means painting")
    print("  cannot measure it: init overwrites the paint before execution begins.")
    print()
    print("  CONSEQUENCE FOR relay P06: a high-water measured by painting the ARM stack")
    print("  would report ~0 and be WRONG. The correct method is a flash-vs-RAM")
    print("  differential — compare post-run linear memory against the init SOURCE bytes")
    print("  in flash; words that differ were written by EXECUTION, not by init.")
    sys.exit(0)
print("  RESULT: at least one painted region WAS touched — a high-water is measurable here.")
print("  Extend this into a scan rather than a two-region probe.")
' || exit 1
