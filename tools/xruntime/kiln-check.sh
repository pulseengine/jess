#!/usr/bin/env bash
# Cross-runtime check: does kiln compute what wasmtime computes on the SHIPPED meld-fused core?
#
# HISTORY, kept because each step was a real defect:
#   * scripts/jess-build.sh once ran `kilnd "$FUSED" --function run-stabilization 2>/dev/null
#     || true`. The fused core has no such export, so it failed every time, and `|| true` made
#     "disagreed" and "could not run" the same reading (AFD-116).
#   * The next version compared the i32 each export returns. That is a POINTER into the return
#     area, measured constant (9488) across three argument sets, so the agreement said nothing
#     about the arithmetic. It was labelled an EXECUTION check, not a value differential.
#   * kiln 0.6.0 decodes the return area itself and prints the record ("returned a 16-byte
#     record through memory: m1: f32 ..."), which made the old `[0] i32` parse read nothing.
#   * kiln 0.9.0 dropped the `kilnd` name and takes its options BEFORE the module path
#     (`kiln --invoke E --arg X mod.wasm`), as `wasmtime run` does.
#
# WHAT THIS CLAIMS NOW: a VALUE differential on mixer#mix. wasmtime's side comes from
# tools/cascade-differential/cascade_ref.py, which instantiates the SAME module under
# wasmtime-py, runs rate#tick -> mixer#mix, and dereferences the return area. kiln is then
# driven with wasmtime's torque as mixer#mix's four flattened f32, and its decoded m1..m4 must
# equal wasmtime's pwm BIT FOR BIT as f32 (see f32bits); a mismatch prints both.
# Plus: every one of the five stage exports must EXECUTE under kiln.
#
# NOT CLAIMED: the other four stages' values (only mixer is compared), or anything about a
# non-saturated operating point. cascade_ref's operating point saturates m1/m2/m4, so three of
# the four outputs are the clamp value; m3 is the one interior value.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
KILN="${KILN:-kiln}"
MOD="${MOD:-$ROOT/.scratch/invoke/c.loom.wasm}"
PY="${PY:-python3}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# Decimal tokens on stdin -> their f32 bit patterns (perl pack "f" rounds to single precision).
f32bits() { perl -ne 'print join(" ", map { sprintf "0x%08x", unpack("L", pack("f", $_)) } split), "\n"'; }

[ -f "$MOD" ] || fail "fused core not found: $MOD — could not run"
command -v "$KILN" >/dev/null 2>&1 || [ -x "$KILN" ] \
  || fail "'$KILN' not found — that is 'could not run the check', NOT 'the check failed'"
kv="$("$KILN" --version 2>&1 | head -1)"
case "$kv" in
  "kiln "*) : ;;
  *) fail "$KILN does not report a kiln version ('$kv') — refusing rather than guessing" ;;
esac
echo "  kiln: $kv"

# The interface version moves between falcon releases while the signatures stay, so read it
# from the module (kiln lists the exports when asked for one that does not exist).
IFACE_VER="$("$KILN" --invoke __list "$MOD" 2>&1 | sed -n 's|.*falcon-cascade/mixer@\([0-9][0-9.]*\)#mix.*|\1|p' | head -1)"
[ -n "$IFACE_VER" ] || fail "could not read the falcon interface version from $MOD — could not run"

# kiln's decoded record -> "m1 m2 m3 m4" as f32 BIT PATTERNS.
# Compared as bits, not decimal strings: kiln prints the shortest decimal that round-trips the
# f32 (0.3489921) while cascade_ref.py prints %.9g of it (0.348992109). Both are the same f32;
# a string compare called that a disagreement (measured on the first run of this version).
kiln_record() {  # $1 export, rest = args
  local e="$1"; shift; local a=() x
  for x in "$@"; do a+=(--arg "$x"); done
  "$KILN" --invoke "$e" "${a[@]}" "$MOD" 2>&1 \
    | awk '$1 ~ /^m[1-4]:$/ && $2 == "f32" { printf "%s%s", (n++ ? " " : ""), $3 } END { print "" }' | f32bits
}

# wasmtime's side. cascade_ref.py prints "torque tx=.. ty=.. tz=.. thrust=.." and
# "pwm m1=.. m2=.. m3=.. m4=..", both already at %.9g.
ref="$("$PY" "$ROOT/tools/cascade-differential/cascade_ref.py" "$MOD" 2>&1)" \
  || { printf '%s\n' "$ref" | sed 's/^/   /' >&2; fail "the wasmtime reference could not run (PY=$PY needs the wasmtime module)"; }
torque="$(printf '%s\n' "$ref" | awk '$1=="torque"{for(i=2;i<=5;i++){split($i,kv,"="); printf "%s%s", (i>2?" ":""), kv[2]} print ""}')"
w_pwm="$(printf '%s\n' "$ref" | awk '$1=="pwm"{for(i=2;i<=5;i++){split($i,kv,"="); printf "%s%s", (i>2?" ":""), kv[2]} print ""}' | f32bits)"
[ "$(wc -w <<<"$torque")" -eq 4 ] || fail "could not read wasmtime's torque from cascade_ref.py — could not run"
[ "$(wc -w <<<"$w_pwm")" -eq 4 ] || fail "could not read wasmtime's pwm from cascade_ref.py — could not run"

e="pulseengine:falcon-cascade/mixer@$IFACE_VER#mix"
# shellcheck disable=SC2086
k_pwm="$(kiln_record "$e" $torque)"
[ "$(wc -w <<<"$k_pwm")" -eq 4 ] || fail "kiln returned ${k_pwm:-nothing} for $e, not a 4-field record — could not run"
echo "  $e($torque)"
echo "    wasmtime  $w_pwm"
echo "    kiln      $k_pwm"
[ "$k_pwm" = "$w_pwm" ] || fail "CROSS-RUNTIME VALUE DISAGREEMENT on $e"
echo "    AGREE on all 4 outputs"

# Every stage export kiln CAN drive must execute. The cascade is not uniform: ekf#estimate takes
# 6 f32 and mixer#mix 4 f32 as values, but the three #tick exports take 18 values that the
# Canonical ABI flattens into ONE pointer to an argument block. Earlier versions of this check
# passed `0` as that pointer and counted the run as "executed" — 3 of its 5 were runs on an
# arbitrary address. kiln 0.9.0 refuses that ([E1771], SR-60: it cannot lower the block yet),
# which is right. Those 3 are reported as NOT DRIVABLE, never as executed and never as failed.
n=0; total=0; failed=""; undrivable=""
for spec in "ekf@$IFACE_VER#estimate:0 0 0 0 0 0" \
            "position@$IFACE_VER#tick:" \
            "attitude@$IFACE_VER#tick:" \
            "mixer@$IFACE_VER#mix:0.25 0.5 0.75 0.125" \
            "rate@$IFACE_VER#tick:"; do
  stage="${spec%%:*}"; a="${spec#*:}"; total=$((total+1))
  if [ -z "$a" ]; then
    out="$("$KILN" --invoke "pulseengine:falcon-cascade/$stage" --arg 0 "$MOD" 2>&1)"
    if grep -q 'E1771' <<<"$out"; then undrivable="$undrivable $stage"; continue; fi
    fail "kiln did NOT refuse the pointer-argument export $stage — a run on address 0 would be counted as executed"
  fi
  # shellcheck disable=SC2046
  if "$KILN" --invoke "pulseengine:falcon-cascade/$stage" $(for x in $a; do printf -- '--arg %s ' "$x"; done) "$MOD" >/dev/null 2>&1
  then n=$((n+1)); else failed="$failed $stage"; fi
done
nu=$(wc -w <<<"$undrivable" | tr -d " ")
[ -z "$failed" ] || fail "kiln failed on a value-argument export:$failed"
echo "  of $total stage exports: $n executed under kiln, $nu not drivable by kiln (pointer arguments, SR-60):$undrivable"
echo "  VALUE differential: 1 of $total (mixer). Executed only: $((n-1)). Not run: $nu."
