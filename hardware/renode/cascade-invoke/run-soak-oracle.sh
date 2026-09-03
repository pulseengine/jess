#!/usr/bin/env bash
# TEST-PIX-033 — the falcon rate->mixer chain executes N TICKS on emulated RT1176 and
# tracks an independent wasmtime reference over the WHOLE run, not just the first tick.
#
# WHY N TICKS. AFD-060 executed ONE invocation. One invocation cannot distinguish a
# correctly lowered integrator from one whose state update was dropped — both produce the
# same first tick. The cascade carries state, so tick i depends on ticks 1..i-1; folding
# every tick's motor-pwm makes that dependence the observable.
#
# NOT A SIMULATOR. The input vector is held constant across all N ticks and no vehicle
# model is integrated. What evolves is the cascade's OWN integrator state. Closing a loop
# around a plant is relay's SIL (lane discipline); jess proves the lowered code still
# tracks it.
#
# CONTROLS, all required:
#   (1) COMPLETION SENTINEL — a partial run would produce a wrong fold that looks like a
#       lowering defect. The image writes 0x1E55B0A5 only after tick N.
#   (2) N-SENSITIVITY — the reference fold at N-1 must DIFFER from the fold at N. If it
#       did not, the fold would be measuring nothing and any N would pass.
#   (3) ENDPOINT MOTION — tick1 must differ from tickN. soak_ref.py refuses to emit a
#       reference where they are equal, and that refusal is itself self-tested.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$D/../../.." && pwd)"
RENODE="${RENODE:-/Users/r/renode-1.16.1/Contents/MacOS/renode}"
PY="${PY:-python3}"
E="$ROOT/.scratch/invoke/soak.elf"
MOD="$ROOT/.scratch/invoke/c.loom.wasm"
N="${N:-64}"                      # MUST match SOAK_N in boot-soak.S; asserted below.
RUNFOR="${RUNFOR:-4.0}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -x "$RENODE" ] || { echo "SKIP: renode not at $RENODE" >&2; exit 2; }
[ -f "$E" ]   || fail "soak image missing — run build.sh first"
[ -f "$MOD" ] || fail "module missing — run build.sh first"

# The tick count lives in TWO places (the image and the reference). Derive the image's
# value from its source and refuse to run if they disagree, rather than silently
# comparing a 64-tick run against a 63-tick reference.
SRC_N="$(grep -oE '^\s*\.equ\s+SOAK_N,\s*[0-9]+' "$D/boot-soak.S" | grep -oE '[0-9]+$')"
[ -n "$SRC_N" ] || fail "could not read SOAK_N from boot-soak.S"
[ "$SRC_N" = "$N" ] || fail "SOAK_N in boot-soak.S is $SRC_N but the oracle is checking N=$N"

read_soak() {   # $1 = elf ; echoes 11 hex words
cat > /tmp/tp35.resc <<EOF
using sysbus
mach create "t35"
machine LoadPlatformDescription @hardware/renode/pixhawk6xrt.repl
sysbus LoadELF @$1
emulation RunFor "$RUNFOR"
pause
echo "B"
sysbus ReadDoubleWord 0x20011200
sysbus ReadDoubleWord 0x20011204
sysbus ReadDoubleWord 0x20011208
sysbus ReadDoubleWord 0x2001120C
sysbus ReadDoubleWord 0x20011210
sysbus ReadDoubleWord 0x20011214
sysbus ReadDoubleWord 0x20011218
sysbus ReadDoubleWord 0x2001121C
sysbus ReadDoubleWord 0x20011220
sysbus ReadDoubleWord 0x20011224
sysbus ReadDoubleWord 0x20011228
echo "E"
EOF
( cd "$ROOT" && "$RENODE" --console --disable-xwt -e "include @/tmp/tp35.resc
quit" 2>&1 ) | perl -pe 's/\e\[[0-9;]*m//g' | "$PY" -c '
import sys,re
g=False;out=[]
for l in sys.stdin:
    l=l.rstrip()
    if l.strip()=="B": g=True; continue
    if l.strip()=="E": break
    if g:
        m=re.fullmatch(r"\s*(0x[0-9a-fA-F]+)\s*",l)
        if m: out.append(m.group(1))
print(" ".join(out))'
}

echo "== 1. run $N ticks on emulated RT1176 =="
W=( $(read_soak "$E") )
[ "${#W[@]}" -eq 11 ] || fail "expected 11 words from the soak region, got ${#W[@]} (${W[*]:-none})"

# CONTROL 1 — completion. Without this a truncated run is indistinguishable from a
# miscompile, and RUNFOR is a guess.
norm() { printf '0x%08X' "$1"; }
sent="$(norm "${W[10]}")"
[ "$sent" = "0x1E55B0A5" ] || fail "completion sentinel is $sent, not 0x1E55B0A5 — the soak did not finish all $N ticks (raise RUNFOR)"
ran="$(norm "${W[0]}")"
[ "$ran" = "$(printf '0x%08X' "$N")" ] || fail "image reports N=$ran, expected $N"
echo "   sentinel 0x1E55B0A5 present, N=$N ticks completed"

echo "== 2. independent wasmtime reference over the SAME module and N =="
REF="$("$PY" "$ROOT/tools/cascade-differential/soak_ref.py" "$MOD" "$N" --format json)" \
  || fail "reference generator failed (it REFUSES to emit a vacuous soak)"
r_t1="$("$PY" -c "import json,sys;print(' '.join('0x%08X'%w for w in json.loads(sys.argv[1])['tick1']))" "$REF")"
r_tN="$("$PY" -c "import json,sys;print(' '.join('0x%08X'%w for w in json.loads(sys.argv[1])['tickN']))" "$REF")"
r_f="$("$PY"  -c "import json,sys;print('0x%08X'%json.loads(sys.argv[1])['fold'])" "$REF")"

g_t1="$(norm "${W[1]}") $(norm "${W[2]}") $(norm "${W[3]}") $(norm "${W[4]}")"
g_tN="$(norm "${W[5]}") $(norm "${W[6]}") $(norm "${W[7]}") $(norm "${W[8]}")"
g_f="$(norm "${W[9]}")"

[ "$g_t1" = "$r_t1" ] || fail "tick 1 pwm: got [$g_t1] want [$r_t1]"
echo "   tick 1  $g_t1  matches"
[ "$g_tN" = "$r_tN" ] || fail "tick $N pwm: got [$g_tN] want [$r_tN]"
echo "   tick $N $g_tN  matches"
[ "$g_f" = "$r_f" ]   || fail "fold over $N ticks: got $g_f want $r_f"
echo "   fold    $g_f  matches over all $((N*4)) pwm words"

echo "== 3. controls =="
# CONTROL 3 — endpoint motion. A frozen integrator reproduces tick 1 forever.
[ "$g_t1" != "$g_tN" ] || fail "tick1 == tickN — the soak observed nothing"
echo "   tick1 != tickN (the integrator advances; the run is not a constant)"

# CONTROL 2 — N-sensitivity. If fold(N-1) equalled fold(N) the fold would be inert and
# any tick count would pass.
REFM="$("$PY" "$ROOT/tools/cascade-differential/soak_ref.py" "$MOD" "$((N-1))" --format json)" || fail "N-1 reference failed"
r_fm="$("$PY" -c "import json,sys;print('0x%08X'%json.loads(sys.argv[1])['fold'])" "$REFM")"
[ "$r_fm" != "$r_f" ] || fail "fold($((N-1))) == fold($N) — the fold is inert, this test would pass for any N"
echo "   fold($((N-1)))=$r_fm != fold($N)=$r_f (the fold tracks tick count)"

# The reference generator's own vacuity guard must be demonstrably alive.
"$PY" "$ROOT/tools/cascade-differential/soak_ref.py" --self-test > /dev/null || fail "soak_ref.py self-test failed"
echo "   soak_ref.py vacuity guard self-test PASS"

# CONTROL 4 — ON-TARGET DISCRIMINATION. Everything above compares one target run to a
# reference; none of it shows the comparison can FAIL on target. This runs the identical
# soak with the data-segment and globals init short-circuited. It must still COMPLETE
# (sentinel present, so the difference is a wrong answer and not a truncated run) and its
# fold must DIFFER. This is what makes AFD-051's embedder promises load-bearing across a
# whole run rather than at tick 1 only — synth emits byte-identical code with or without
# the --embedder-* flags, so nothing else would tell us.
NCE="$ROOT/.scratch/invoke/soak_nc2.elf"
if [ -f "$NCE" ]; then
  NW=( $(read_soak "$NCE") )
  [ "${#NW[@]}" -eq 11 ] || fail "soak control returned ${#NW[@]} words, expected 11"
  nc_sent="$(norm "${NW[10]}")"; nc_fold="$(norm "${NW[9]}")"
  [ "$nc_sent" = "0x1E55B0A5" ] || fail "soak control did not COMPLETE (sentinel $nc_sent) — a truncated run is not evidence of discrimination"
  [ "$nc_fold" != "$r_f" ] || fail "soak control folded to $nc_fold, IDENTICAL to the reference — skipping the embedder init changed nothing, so this oracle cannot fail on target"
  echo "   init-skipped control completed and folded $nc_fold != $r_f (the oracle discriminates on target)"
else
  fail "soak_nc2.elf missing — run build.sh; without it nothing shows this oracle can fail"
fi

echo
echo "Result: PASS — the falcon rate->mixer chain ran $N ticks on emulated RT1176"
echo "        and tracked the wasmtime reference bit-exact at tick 1, tick $N,"
echo "        and across a fold of all $((N*4)) motor-pwm words."
