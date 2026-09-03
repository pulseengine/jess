#!/usr/bin/env bash
# TEST-PIX-032 — falcon rate@0.7.0#tick EXECUTES on emulated RT1176 Cortex-M7 and
# reproduces relay's SIL reference torque bit-exact.
#
# AFD-056 showed the self-contained image never enters a stage: it inits and spins. This
# harness calls one, and checks the answer rather than the fact of running — 213,439
# instructions of memcpy taught this campaign that "it ran" is not "it worked".
#
# TWO NEGATIVE CONTROLS, both required, because the headline number alone proves little:
#   (1) PERTURB THE INPUT   -> the torque must CHANGE. A stage that returned a constant
#       would match the reference forever.
#   (2) SKIP THE EMBEDDER INIT -> the result must be WRONG. This is what makes AFD-051's
#       data-segment and R9-globals tables demonstrably load-bearing rather than
#       ceremonial; synth emits byte-identical code with or without the flags, so nothing
#       else would tell us the promises were kept.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$D/../../.." && pwd)"
RENODE="${RENODE:-/Users/r/renode-1.16.1/Contents/MacOS/renode}"
E="$ROOT/.scratch/invoke/invoke.elf"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# A per-run temp file. These were fixed paths named after the HAND-INVENTED ids
# (tp34/tp35) that were never rivet ids; two concurrent oracle runs also clobbered
# each other's script. Both found by clean-room verification.
RESC="$(mktemp -t jess-oracle.XXXXXX).resc"
trap 'rm -f "$RESC"' EXIT
[ -x "$RENODE" ] || { echo "SKIP: renode not at $RENODE" >&2; exit 2; }
[ -f "$E" ] || fail "image missing — run build.sh first"

read_words() {   # $1 = elf
  cat > $RESC <<EOF
using sysbus
mach create "t34"
machine LoadPlatformDescription @hardware/renode/pixhawk6xrt.repl
sysbus LoadELF @$1
emulation RunFor "0.2"
pause
echo "B"
sysbus ReadDoubleWord 0x20011000
sysbus ReadDoubleWord 0x20011004
sysbus ReadDoubleWord 0x20011008
sysbus ReadDoubleWord 0x2001100C
sysbus ReadDoubleWord 0x20011010
sysbus ReadDoubleWord 0x20011100
sysbus ReadDoubleWord 0x20011104
sysbus ReadDoubleWord 0x20011108
sysbus ReadDoubleWord 0x2001110C
sysbus ReadDoubleWord 0x20011110
sysbus ReadDoubleWord 0x20011114
echo "E"
EOF
  ( cd "$ROOT" && "$RENODE" --console --disable-xwt -e "include @$RESC
quit" 2>&1 ) | perl -pe 's/\e\[[0-9;]*m//g' | python3 -c '
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

# 0-4 torque block (RESULT), 5-9 pwm block (CHAIN), 10 sentinel (CHAIN+20).
# The sentinel moved when the harness became a two-stage chain; it is read from where
# boot.S actually writes it rather than from where it used to be.
W=($(read_words "$E"))
[ "${#W[@]}" -ge 11 ] || fail "could not read the result blocks (got ${#W[@]} words)"
SENT="${W[10]}"
[ "$(printf '%d' "$SENT")" = "$(printf '%d' 0x1E55D09E)" ] \
  || fail "completion sentinel absent (got $SENT) — the harness did not reach the end"

echo "== stage 1 — rate@0.7.0#tick on emulated RT1176 Cortex-M7 =="
printf '   ret offset %s\n   tx %s\n   ty %s\n   tz %s\n   thrust %s\n' "${W[0]}" "${W[1]}" "${W[2]}" "${W[3]}" "${W[4]}"
EXP=(0x3F800000 0x3EF1EC81 0xBE168816 0x3F000000)
for i in 0 1 2 3; do
  a=$(printf '%d' "${W[$((i+1))]}"); b=$(printf '%d' "${EXP[$i]}")
  [ "$a" = "$b" ] || fail "torque word $i: got ${W[$((i+1))]} want ${EXP[$i]} — does NOT match relay's SIL reference"
done
echo "   MATCHES relay's SIL reference bit-exact (tx=1 ty=0.472507507 tz=-0.147003502 thrust=0.5)"

echo "== stage 2 — mixer@0.7.0#mix, fed by that torque ON TARGET =="
printf '   pwm offset %s\n   m1 %s\n   m2 %s\n   m3 %s\n   m4 %s\n' "${W[5]}" "${W[6]}" "${W[7]}" "${W[8]}" "${W[9]}"
EXPP=(0x00000000 0x00000000 0x3EB2AF18 0x3F800000)
for i in 0 1 2 3; do
  a=$(printf '%d' "${W[$((i+6))]}"); b=$(printf '%d' "${EXPP[$i]}")
  [ "$a" = "$b" ] || fail "pwm word $i: got ${W[$((i+6))]} want ${EXPP[$i]} — does NOT match the wasmtime differential"
done
echo "   MATCHES the wasmtime differential bit-exact (m1=0 m2=0 m3=0.348992109 m4=1, sum 1.34899211)"
echo "   NOTE both stages come from ONE rate#tick invocation — the cascade integrates, so a"
echo "   second call to observe the intermediate would return a different torque (AFD-048)."

echo "== NC1: perturb the input — the torque must move =="
[ -f "$ROOT/.scratch/invoke/nc1.elf" ] || fail "nc1.elf missing — build.sh must emit it"
N1=($(read_words "$ROOT/.scratch/invoke/nc1.elf"))
[ "${#N1[@]}" -ge 10 ] || fail "NC1 produced no result block"
same=1; for i in 1 2 3 4 6 7 8 9; do [ "${N1[$i]}" = "${W[$i]}" ] || same=0; done
[ "$same" = "0" ] || fail "VACUOUS: a perturbed input produced the IDENTICAL torque — the stage is not reading its argument"
echo "   perturbed wy -> tx ${N1[1]} ty ${N1[2]} tz ${N1[3]} thrust ${N1[4]}  (DISTINCT)"

echo "== NC2: skip the embedder init — the result must be WRONG =="
[ -f "$ROOT/.scratch/invoke/nc2.elf" ] || fail "nc2.elf missing — build.sh must emit it"
N2=($(read_words "$ROOT/.scratch/invoke/nc2.elf"))
if [ "${#N2[@]}" -ge 10 ]; then
  match=1; for i in 1 2 3 4 6 7 8 9; do [ "${N2[$i]}" = "${W[$i]}" ] || match=0; done
  [ "$match" = "0" ] || fail "VACUOUS: skipping data-segment + globals init changed NOTHING — the embedder obligations are not load-bearing here, so this test proves nothing about them"
  echo "   without init -> tx ${N2[1]} ty ${N2[2]} tz ${N2[3]} thrust ${N2[4]}  (WRONG, as required)"
else
  echo "   without init -> the harness did not complete (also an acceptable failure mode)"
fi

echo
echo "PASS — a TWO-STAGE falcon chain (rate -> mixer) EXECUTED on emulated RT1176 Cortex-M7."
echo "       Both stages reproduce their references bit-exact from a single invocation;"
echo "       a perturbed input moves them, and removing the embedder init breaks them."
