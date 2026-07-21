#!/usr/bin/env bash
# Gust byte-exact pass-through oracle (REQ-PIX-004 PART-P02 (a)).
#
# Asserts the F100 gust failsafe forwards the M7's per-motor commands BYTE-EXACT — no
# re-mix, no floors — against relay's REAL conformance fixture (falcon-v1.124 PART-P02):
# hardware/gust/fixtures/f100-passthrough-v1.csv (expected F100 output == input, per row).
#
# POSITIVE (must pass): hardware/gust/passthrough.wat reproduces every fixture row byte-exact.
# NEGATIVE CONTROL (must have teeth): hardware/gust/remix-negative.wat (a symmetric averaging
# re-mix) MUST DIVERGE on the rank-3 rotor-out rows where motors are asymmetrically zeroed —
# else a re-mix regression (the relay v1.114 parasitic-moment class) could slip through.
#
# Runs the wasm on wasmtime (host). The pass-through core is FPU-free (i32 bit copy), so it
# also lowers on the F100 target (Cortex-M3, soft-float) — checked separately if SYNTH is set.
set -uo pipefail
D="$(cd "$(dirname "$0")/../.." && pwd)"
WT="${WASMTIME:-wasmtime}"; WASM_TOOLS="${WASM_TOOLS:-wasm-tools}"
FIX="$D/hardware/gust/fixtures/f100-passthrough-v1.csv"
work="$(mktemp -d)"

command -v "$WT" >/dev/null 2>&1 || { echo "ORACLE SKIP: no wasmtime (set WASMTIME=)"; exit 2; }
[ -f "$FIX" ] || { echo "ORACLE FAIL: fixture missing: $FIX"; exit 1; }
"$WASM_TOOLS" parse "$D/hardware/gust/passthrough.wat"    -o "$work/pt.wasm"    || exit 1
"$WASM_TOOLS" parse "$D/hardware/gust/remix-negative.wat" -o "$work/remix.wasm" || exit 1

hex2s() { local h=$((16#$1)); [ "$h" -ge 2147483648 ] && echo $((h-4294967296)) || echo "$h"; }
s2hex() { printf '%08x' $(( $1 & 0xffffffff )); }
invoke() { "$WT" run --invoke pt "$1" "$2" "$3" "$4" "$5" "$6" 2>/dev/null; }  # wasm m0 m1 m2 m3 i

rows=0 checks=0 pass_ok=0 neg_divergences=0 asym_rows=0
while IFS=, read -r phase m0 m1 m2 m3; do
  case "$phase" in \#*|""|phase) continue;; esac
  rows=$((rows+1))
  a0=$(hex2s "$m0"); a1=$(hex2s "$m1"); a2=$(hex2s "$m2"); a3=$(hex2s "$m3")
  declare -a inbits=("$m0" "$m1" "$m2" "$m3")
  # POSITIVE: pass-through must reproduce each motor byte-exact
  for i in 0 1 2 3; do
    checks=$((checks+1))
    got=$(s2hex "$(invoke "$work/pt.wasm" "$a0" "$a1" "$a2" "$a3" "$i")")
    [ "$got" = "${inbits[$i]}" ] && pass_ok=$((pass_ok+1)) || echo "  PASS-THROUGH MISMATCH $phase motor$i: expected ${inbits[$i]} got $got"
  done
  # NEGATIVE CONTROL: on rows with an asymmetric zero, the re-mix must diverge from byte-exact
  if printf '%s\n' "$m0" "$m1" "$m2" "$m3" | grep -q '^00000000$'; then
    asym_rows=$((asym_rows+1)); diverged=0
    for i in 0 1 2 3; do
      got=$(s2hex "$(invoke "$work/remix.wasm" "$a0" "$a1" "$a2" "$a3" "$i")")
      [ "$got" != "${inbits[$i]}" ] && diverged=1
    done
    [ "$diverged" = 1 ] && neg_divergences=$((neg_divergences+1))
  fi
done < "$FIX"

echo "fixture: $rows rows, $checks byte-exact checks; asymmetric-zero rows: $asym_rows"
fail=0
if [ "$pass_ok" != "$checks" ] || [ "$checks" = 0 ]; then echo "ORACLE FAIL: pass-through not byte-exact ($pass_ok/$checks)"; fail=1; fi
if [ "$neg_divergences" != "$asym_rows" ] || [ "$asym_rows" = 0 ]; then
  echo "ORACLE FAIL: negative control weak — re-mix did NOT diverge on all asymmetric-zero rows ($neg_divergences/$asym_rows)"; fail=1; fi
[ "$fail" = 0 ] || exit 1
echo "GUST PASS-THROUGH OK — $pass_ok/$checks byte-exact vs relay's PART-P02 fixture; re-mix diverges on all $asym_rows asymmetric-zero rows (negative control has teeth)."
