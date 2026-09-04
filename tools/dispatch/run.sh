#!/usr/bin/env bash
# TEST-PIX-035 — gale-nano's dispatch loop, MEASURED rather than assumed (DD-025, gale#223).
#
# gale#223 states: "Drive one round at time `now`: fire the tickless alarm, then drain every
# ready task exactly once through `taskdisp.poll-task`", and that the embedder IMPLEMENTS
# {gust:hal/mmio, gust:os/taskdisp} while it CALLS {gust:os/exec, time, timer, spawn, log}.
# Both halves are verified here against the SHIPPED gale-nano 0.7.0 artifact.
#
# WHY A PROBE COMPONENT: jess's existing taskdisp implementations returned 0 and recorded
# NOTHING, so "poll-round drained the task" and "poll-round did nothing" produced identical
# observable state. app/gust-dispatch-probe counts its own invocations; app/dispatch-driver
# sequences admit/poll-round/read-back INSIDE the graph, because each `wasmtime run --invoke`
# is a fresh instantiation and the sequence cannot span three CLI calls.
#
# Each experiment is its own exported function, so each runs in a FRESH instance — which is
# what makes with-admit / without-admit a valid control pair rather than two readings of one
# accumulating counter (the AFD-048 mistake).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
OUT="${OUT:-$ROOT/.scratch/dispatch}"; mkdir -p "$OUT"
SCRATCH="${SCRATCH:-$ROOT/.scratch}"
NANO="$SCRATCH/galenano7/gale-nano-0.7.0.wasm"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for t in cargo wasm-tools wac wasmtime; do command -v "$t" >/dev/null || fail "$t not on PATH"; done
SCRATCH="$SCRATCH" "$ROOT/tools/deps/check.sh" --only galenano7 >/dev/null 2>&1 \
  || fail "gale-nano does not match its pin — refusing to measure a lookalike"

echo "== 1. build the probe and the driver =="
for c in gust-dispatch-probe dispatch-driver; do
  ( cd "$ROOT/app/$c" && cargo build --release --target wasm32-unknown-unknown ) >/dev/null 2>&1 || fail "$c build"
done
wasm-tools component new "$ROOT/app/gust-dispatch-probe/target/wasm32-unknown-unknown/release/jess_gust_dispatch_probe.wasm" -o "$OUT/probe.wasm" || fail "probe componentize"
wasm-tools component new "$ROOT/app/dispatch-driver/target/wasm32-unknown-unknown/release/jess_dispatch_driver.wasm"      -o "$OUT/driver.wasm" || fail "driver componentize"
cp "$NANO" "$OUT/gale-nano.wasm"

# The VARIANT probe returns 1 from poll-task instead of 0. EXACTLY ONE variable differs;
# it is what turns "the return value means something" from a guess into a measurement.
rm -rf "$OUT/probe1"; mkdir -p "$OUT/probe1"
cp -r "$ROOT/app/gust-dispatch-probe/Cargo.toml" "$ROOT/app/gust-dispatch-probe/src" "$ROOT/app/gust-dispatch-probe/wit" "$OUT/probe1/"
sed -i.bak 's|path = "../bump-alloc"|path = "'"$ROOT"'/app/bump-alloc"|' "$OUT/probe1/Cargo.toml"
python3 - "$OUT/probe1/src/lib.rs" <<'EOP' || fail "variant edit"
import sys
p=sys.argv[1]; s=open(p).read()
old="        ID_MASK.fetch_or(id, Ordering::Relaxed);\n        1\n    }"
new="        ID_MASK.fetch_or(id, Ordering::Relaxed);\n        0\n    }"
if old not in s: sys.exit("variant anchor not found — the probe's return value moved")
open(p,'w').write(s.replace(old,new))
EOP
( cd "$OUT/probe1" && cargo build --release --target wasm32-unknown-unknown ) >/dev/null 2>&1 || fail "variant build"
wasm-tools component new "$OUT/probe1/target/wasm32-unknown-unknown/release/jess_gust_dispatch_probe.wasm" -o "$OUT/probe1.wasm" || fail "variant componentize"
cmp -s "$OUT/probe.wasm" "$OUT/probe1.wasm" && fail "the ret-0 variant is byte-identical to the ret-1 probe — the control is inert"

echo "== 2. compose against SHIPPED gale-nano 0.7.0 =="
cp "$ROOT/tools/dispatch/compose.wac" "$OUT/"
( cd "$OUT" && wac compose --dep jess:gust-dispatch-probe=probe.wasm  --dep gust:runtime=gale-nano.wasm --dep jess:dispatch-driver=driver.wasm compose.wac -o exp.wasm  ) || fail "compose (ret1)"
( cd "$OUT" && wac compose --dep jess:gust-dispatch-probe=probe1.wasm --dep gust:runtime=gale-nano.wasm --dep jess:dispatch-driver=driver.wasm compose.wac -o exp0.wasm ) || fail "compose (ret0)"

inv() { wasmtime run --invoke "$2" "$1" 2>/dev/null | tail -1; }
want() { # $1 file $2 fn $3 expected $4 why
  local got; got="$(inv "$1" "$2")"
  [ "$got" = "$3" ] || fail "$2 on $(basename "$1") = ${got:-<none>}, expected $3 — $4"
  printf '   %-24s %-12s %s\n' "$2" "$got" "$4"
}

echo "== 3. does poll-round reach poll-task at all? =="
want "$OUT/exp.wasm" "with-admit()"    1 "a round after admit polls the task ONCE"
want "$OUT/exp.wasm" "without-admit()" 0 "CONTROL: same round, no admit -> poll-task NOT reached"

echo "== 4. 'drain EVERY ready task' =="
want "$OUT/exp.wasm" "two-tasks-one-round()" 2 "two admitted tasks, one round -> two polls"

echo "== 5. the return value of poll-task is LOAD-BEARING (and undocumented upstream) =="
# gale-nano 0.7.0 ships `poll-task: func(id: u32) -> u32` with NO documented semantics.
# These two lines are the measurement that gives it meaning.
want "$OUT/exp.wasm"  "one-task-two-rounds()" 1 "returning 1 -> task is NOT re-polled"
want "$OUT/exp0.wasm" "one-task-two-rounds()" 2 "returning 0 -> task IS re-polled next round"
# gale's OWN view, independent of jess's counter.
want "$OUT/exp.wasm"  "state-before-round()" 1 "admitted task starts in state 1"
want "$OUT/exp.wasm"  "state-after-round()"  2 "after a round with ret 1 -> state 2"
want "$OUT/exp0.wasm" "state-after-round()"  1 "after a round with ret 0 -> STILL state 1"

echo "== 6. the observation itself is not vacuous =="
want "$OUT/exp.wasm" "unpolled-id()" 4294967295 "CONTROL: sentinel is reachable when poll-task never runs"
want "$OUT/exp.wasm" "observed-id()"          0 "so a reported id of 0 is a REAL handle, not an absence"
want "$OUT/exp.wasm" "admitted-handle()"      0 "gale hands out handle 0 first — which is why the sentinel cannot be 0"

echo
echo "Result: PASS — gale-nano 0.7.0's poll-round drains admitted tasks through taskdisp.poll-task,"
echo "        every ready task once per round, and the poll-task RETURN VALUE decides whether the"
echo "        task is re-polled: 1 completes it (state 1 -> 2), 0 leaves it ready. Executed in"
echo "        wasmtime against the shipped, digest-pinned artifact. NOT on target."
