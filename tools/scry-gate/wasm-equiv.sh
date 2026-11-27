#!/usr/bin/env bash
# scry-run as a WASI p2 component: the same source built for wasm32-wasip2, run under
# wasmtime, must give byte-identical stdout and the same exit code as the native build.
#
# Owner decision 2026-11-27 ("run what we build"): jess's host tools run as components on our
# own engine where they can. scry-run needs no host-only feature (it reads one file and prints
# JSON), so the component is the first one. kiln joins as an advisory runtime after kiln#480.
#
# Cases (the denominator is printed):
#   1. the fused falcon core run.sh produced   -> both exit 0, stdout identical
#   2. a file that is not wasm (this script)   -> both exit non-zero, stdout AND stderr identical
# Negative control: the comparator is run on case 1's output against a copy with one byte
# changed, and must report a difference, or this script fails.
#
# Exit 0 = every case identical. 1 = a case differed. 2 = could not run (no wasmtime, no
# wasm32-wasip2 target, no input): "could not run" is never reported as "identical".
#
# Not covered: panic paths (native unwinds and exits 101, the component traps), and kiln.
# stderr is required identical only in the failing case; in case 1 it is reported.
#
# Usage: tools/scry-gate/wasm-equiv.sh <fused-core.wasm>
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CRATE="$ROOT/tools/scry-gate/scry-run"
WORK="$ROOT/tools/scry-gate/.work/equiv"
WASMTIME="${WASMTIME:-wasmtime}"
cannot() { echo "COULD NOT RUN: $*" >&2; exit 2; }

FUSED="${1:-}"
[ -f "$FUSED" ] || cannot "no fused core given or not a file: '${FUSED}'"
"$WASMTIME" --version >/dev/null 2>&1 || cannot "'$WASMTIME' does not run (set WASMTIME=)"
rm -rf "$WORK" && mkdir -p "$WORK/in" || cannot "cannot create $WORK"

( cd "$CRATE" && cargo build --release --locked -q ) || cannot "native build failed"
( cd "$CRATE" && cargo build --release --locked -q --target wasm32-wasip2 ) \
  || cannot "wasm32-wasip2 build failed (rustup target add wasm32-wasip2)"
NATIVE="$CRATE/target/release/scry-run"
COMPONENT="$CRATE/target/wasm32-wasip2/release/scry-run.wasm"
echo "component: $(wc -c <"$COMPONENT" | tr -d ' ') B, sha256 $(shasum -a 256 "$COMPONENT" | awk '{print $1}')"
echo "runtime:   $("$WASMTIME" --version)"
# Rust >= 1.100 std on wasm32-wasip2 imports wasi:cli/exit `exit-with-code` even when main exits
# through std::process::exit (measured with 1.100.0), and wasmtime 42 links it only with
# -S cli-exit-with-code. Without the flag the component cannot start (CI run 45984297106).
WT_FLAGS=()
if grep -aq exit-with-code "$COMPONENT"; then
  WT_FLAGS=(-S cli-exit-with-code); echo "imports exit-with-code: yes -> wasmtime -S cli-exit-with-code"
else
  echo "imports exit-with-code: no"
fi

cp "$FUSED" "$WORK/in/case1.wasm"
cp "$0" "$WORK/in/case2.wasm"

# run_case NAME EXPECT(zero|nonzero) -> 0 identical, 1 differ
run_case() {
  local c="$1" expect="$2" n w
  "$NATIVE" "$WORK/in/$c.wasm" >"$WORK/$c.native.out" 2>"$WORK/$c.native.err"; n=$?
  "$WASMTIME" run ${WT_FLAGS[@]+"${WT_FLAGS[@]}"} --dir "$WORK/in::/in" "$COMPONENT" "/in/$c.wasm" \
    >"$WORK/$c.wasm.out" 2>"$WORK/$c.wasm.err"; w=$?
  local ok=1
  [ "$n" = "$w" ] || { echo "  $c: exit native=$n component=$w DIFFER"; ok=0; }
  if [ "$expect" = zero ]; then [ "$n" = 0 ] || { echo "  $c: native exit $n, expected 0"; ok=0; }
  else [ "$n" != 0 ] || { echo "  $c: native exit 0, expected non-zero"; ok=0; }; fi
  cmp -s "$WORK/$c.native.out" "$WORK/$c.wasm.out" \
    || { echo "  $c: stdout DIFFER"; diff "$WORK/$c.native.out" "$WORK/$c.wasm.out" | head -10; ok=0; }
  local e=identical; cmp -s "$WORK/$c.native.err" "$WORK/$c.wasm.err" || e=differs
  # A failing case must fail the same way: identical stderr, so a component that never started
  # (a runtime error, exit 1, empty stdout) cannot pass as "answered no".
  if [ "$expect" = nonzero ] && [ "$e" = differs ]; then echo "  $c: stderr DIFFER"; ok=0; fi
  if [ "$ok" = 0 ]; then
    echo "  $c: component stderr (first 15 lines):"; head -15 "$WORK/$c.wasm.err" | sed 's/^/    /'
  fi
  echo "  $c: exit $n/$w, stdout $(wc -c <"$WORK/$c.native.out" | tr -d ' ') B sha256 $(shasum -a 256 "$WORK/$c.native.out" | awk '{print $1}'), stderr $e"
  [ "$ok" = 1 ]
}

same=0; total=0
for spec in case1:zero case2:nonzero; do
  total=$((total + 1))
  run_case "${spec%%:*}" "${spec##*:}" && same=$((same + 1))
done

# Negative control: a one-byte change in the component's stdout must be seen as a difference.
cp "$WORK/case1.wasm.out" "$WORK/mutant.out"
printf '1' | dd of="$WORK/mutant.out" bs=1 seek=10 conv=notrunc 2>/dev/null
if cmp -s "$WORK/case1.native.out" "$WORK/mutant.out"; then
  echo "NEGATIVE CONTROL FAILED: the comparator did not see a one-byte change" >&2; exit 1
fi
echo "negative control: one changed byte is reported as a difference"

echo "Result: $same of $total cases identical (native vs wasm32-wasip2 under wasmtime)"
[ "$same" = "$total" ]
