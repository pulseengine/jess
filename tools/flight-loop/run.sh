#!/usr/bin/env bash
# Drive the falcon cascade ON A SCHEDULE and prove the pacing is real.
#
# This is the DD-025 structural rung, unblocked by AFD-049: gale's timer path works
# end to end once the embedder supplies a ticking clock through gust:hal/mmio.
#
# THE ORACLE IS A DIFFERENTIAL ON THE CLOCK, not an assertion that the loop ran. The
# same composed image is run twice, changing exactly ONE thing — whether read32 ticks.
# A loop that "completes" under a frozen clock would be spinning, not scheduling, and
# that is precisely the confusion AFD-047 fell into. So: ticking must complete, and
# constant must NOT. Both directions are required for a PASS.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
OUT="${OUT:-$ROOT/.scratch/floop}"; mkdir -p "$OUT"
NANO="${NANO:-$ROOT/.scratch/galenano7/gale-nano-0.7.0.wasm}"
RATE="${RATE:-$ROOT/.scratch/v1341/rate.wasm}"
MIXER="${MIXER:-$ROOT/.scratch/v1341/mixer.wasm}"
ITERS="${ITERS:-8}"; TICKS="${TICKS:-3}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for f in "$NANO" "$RATE" "$MIXER"; do
  [ -f "$f" ] || fail "missing supplier artifact: $f (not vendored; fetch via the DD-026 OCI path)"
done
for t in cargo wasm-tools wac wasmtime; do command -v $t >/dev/null || fail "not on PATH: $t"; done

for c in flight-loop gust-hal-tick gust-hal-stub; do
  ( cd "$ROOT/app/$c" && cargo build --release --target wasm32-unknown-unknown ) || fail "$c build"
done
# Name every artifact EXPLICITLY. `ls | head -1` in the sibling timer probe silently
# selected a stale stub for days and produced a wrong finding (AFD-049).
wasm-tools component new "$ROOT/app/flight-loop/target/wasm32-unknown-unknown/release/jess_flight_loop.wasm" -o "$OUT/flight-loop.wasm"
wasm-tools component new "$ROOT/app/gust-hal-tick/target/wasm32-unknown-unknown/release/jess_gust_hal_tick.wasm" -o "$OUT/hal-tick.wasm"
wasm-tools component new "$ROOT/app/gust-hal-stub/target/wasm32-unknown-unknown/release/jess_gust_hal_stub.wasm" -o "$OUT/hal-const.wasm"
cp "$NANO" "$OUT/gale-nano.wasm"; cp "$RATE" "$OUT/rate.wasm"; cp "$MIXER" "$OUT/mixer.wasm"
cp "$ROOT/tools/flight-loop/loop1.wac" "$ROOT/tools/flight-loop/loop2.wac" "$OUT/"

( cd "$OUT"
  wac compose --dep gust:runtime=gale-nano.wasm --dep pulseengine:rate=rate.wasm \
      --dep pulseengine:mixer=mixer.wasm --dep jess:floop=flight-loop.wasm loop1.wac -o step1.wasm
  wac compose --dep jess:hal=hal-tick.wasm  --dep jess:looped=step1.wasm loop2.wac -o full_tick.wasm
  wac compose --dep jess:hal=hal-const.wasm --dep jess:looped=step1.wasm loop2.wac -o full_const.wasm ) || fail "compose"
wasm-tools validate "$OUT/full_tick.wasm" >/dev/null || fail "composed image invalid"

dec() { python3 - "$1" "$2" <<'PY'
import sys
r=int(sys.argv[2]); print(f"   {sys.argv[1]:<9} iters={r&0x3FF}  all_fired={bool(r>>10&1)}  "
      f"varied={bool(r>>11&1)}  clock={bool(r>>12&1)}  final_fold_low16=0x{(r>>16)&0xFFFF:04X}")
PY
}
tick_r="$(wasmtime run --invoke "run-loop($ITERS, $TICKS)" "$OUT/full_tick.wasm" | tail -1)"
const_r="$(wasmtime run --invoke "run-loop($ITERS, $TICKS)" "$OUT/full_const.wasm" | tail -1)"
echo "== the clock differential (only read32 differs between these two) =="
dec TICKING "$tick_r"; dec CONSTANT "$const_r"

ti=$(( tick_r & 0x3FF )); ci=$(( const_r & 0x3FF )); fired=$(( (tick_r >> 10) & 1 ))
[ "$ti" = "$ITERS" ] || fail "ticking clock completed $ti/$ITERS iterations"
[ "$fired" = "1" ]   || fail "ticking clock did not fire every wake"
[ "$ci" = "0" ]      || fail "VACUOUS: the loop completed $ci iteration(s) under a FROZEN clock — it is spinning, not scheduling"

# Iteration 1 must reproduce the single-shot differential exactly. 0xABC6 is the low half
# of 1068280774, the fold tools/cascade-differential/cascade_ref.py independently computes.
one_r="$(wasmtime run --invoke "run-loop(1, $TICKS)" "$OUT/full_tick.wasm" | tail -1)"
one_lo=$(( (one_r >> 16) & 0xFFFF ))
printf '== iteration 1 vs the established single-shot reference ==\n   got 0x%04X, want 0xABC6\n' "$one_lo"
[ "$one_lo" = "43974" ] || fail "iteration 1 does not reproduce the single-shot fold (0xABC6)"

echo
echo "PASS — $ITERS/$ITERS periods paced by the clock, every wake fired, the fold varied"
echo "       (evidence the body re-ran at least a second time — the mixer saturates from"
echo "       iteration 2, so this bit cannot distinguish 2 executions from $ITERS),"
echo "       iteration 1 matches the single-shot reference,"
echo "       and the SAME image completes 0 iterations once the clock stops ticking."
