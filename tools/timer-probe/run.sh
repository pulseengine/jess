#!/usr/bin/env bash
# Exercise gale's app-timer shape (gale#223) against the SHIPPED gale-nano and report,
# as a decoded bitfield, exactly which timer semantics hold and whether a wake ever fires.
#
# WHY A BITFIELD AND NOT PASS/FAIL: five independent properties are under test. A boolean
# collapses them, and the interesting outcome here is precisely that MOST pass while one
# does not — a pass/fail oracle would have said "fail" and taught nothing.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
OUT="${OUT:-$ROOT/.scratch/tprobe}"; mkdir -p "$OUT"
NANO="${NANO:-$ROOT/.scratch/galenano7/gale-nano-0.7.0.wasm}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -f "$NANO" ] || fail "gale-nano not found at $NANO (supplier artifact, not vendored)"

# AFD-053 S2: verify the external artifacts against tools/deps/artifacts.pins BEFORE
# measuring anything. Without this the oracle runs against whatever happens to be in
# .scratch/ and reports a result that reads reproducible and is not.
"$ROOT/tools/deps/check.sh" >/dev/null 2>&1 || {
  "$ROOT/tools/deps/check.sh" >&2
  fail "external artifacts do not match tools/deps/artifacts.pins (see above)"
}

for c in timer-probe gust-hal-tick; do
  ( cd "$ROOT/app/$c" && cargo build --release --target wasm32-unknown-unknown ) || fail "$c build"
done
wasm-tools component new "$ROOT/app/timer-probe/target/wasm32-unknown-unknown/release/jess_timer_probe.wasm" -o "$OUT/probe.wasm"
# NAME THE ARTIFACT EXPLICITLY. The earlier version took `ls .../*.wasm | head -1` on the
# assumption that the tick crate kept the stub's lib name. It does not — the package is
# `jess-gust-hal-tick`, so cargo emits jess_gust_hal_tick.wasm. But app/gust-hal-tick was
# created with `cp -r app/gust-hal-stub`, which copied the stub's target/ dir along with it,
# leaving a STALE jess_gust_hal_stub.wasm that sorts FIRST alphabetically. So `head -1`
# silently composed the CONSTANT stub every time and the ticking HAL was never once tested —
# which is how AFD-047 concluded the clock could not be unfrozen. See AFD-049.
TICK="$ROOT/app/gust-hal-tick/target/wasm32-unknown-unknown/release/jess_gust_hal_tick.wasm"
[ -f "$TICK" ] || fail "ticking HAL not built at $TICK"
# Refuse to proceed if a stale stub artifact is sitting in the tick crate's target dir.
stale="$ROOT/app/gust-hal-tick/target/wasm32-unknown-unknown/release/jess_gust_hal_stub.wasm"
[ -e "$stale" ] && fail "stale stub artifact in the tick crate's target dir: $stale — remove it"
wasm-tools component new "$TICK" -o "$OUT/hal-tick.wasm"
cp "$NANO" "$OUT/gale-nano.wasm"
cp "$ROOT/tools/timer-probe/probe.wac" "$ROOT/tools/timer-probe/hal.wac" "$OUT/"

( cd "$OUT"
  wac compose --dep gust:runtime=gale-nano.wasm --dep jess:probe=probe.wasm probe.wac -o probed.wasm
  wac compose --dep jess:hal=hal-tick.wasm --dep jess:probed=probed.wasm hal.wac -o full.wasm ) || fail "compose"
wasm-tools validate "$OUT/full.wasm" >/dev/null || fail "composed image invalid"

R="$(wasmtime run --invoke 'run()' "$OUT/full.wasm" | tail -1)"
python3 - "$R" <<'PY'
import sys
r = int(sys.argv[1])
bits = [
    "clock does real arithmetic on our argument (deadline(t0,1) != t0)",
    "spawn.start yields a handle that is not the INVALID sentinel",
    "timer.sleep(h,1) reports armed (== 0)",
    "timer.slept(h) returns a DEFINED state (not INVALID)",
    "NEGATIVE CONTROL: timer.sleep(INVALID,1) == INVALID",
    "time::now() ADVANCES across 1000 spins",
]
for i, n in enumerate(bits):
    print(f"  bit{i}  {'PASS' if r >> i & 1 else 'FAIL'}  {n}")
last    = (r >> 6) & 0x3
polls   = (r >> 8) & 0x3FFF
elapsed = (r >> 22) & 0x3FF
print(f"\n  polls made = {polls}   last slept() = {last}   elapsed_at = {elapsed}")
if elapsed:
    print(f"  -> the wake FIRED after {elapsed} poll(s) — the timer path WORKS end to end")
elif polls >= 9999:
    print("  -> loop ran to EXHAUSTION and the wake never fired")
    print("     (this is the DD-025 observation; it is NOT an early break)")
else:
    print(f"  -> broke early at poll {polls} — NOT loop exhaustion, do not read this as evidence")

# Gate on the properties, not just on the build steps.
missing = [i for i in range(6) if not (r >> i) & 1]
if missing:
    print(f"\nFAIL: {len(missing)} of 6 properties did not hold: bits {missing}")
    sys.exit(1)
if not elapsed:
    print("\nFAIL: the wake never fired — the timer path did not close")
    sys.exit(1)
print("\nPASS — 6/6 properties hold and the wake fired.")
PY
