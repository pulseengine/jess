#!/usr/bin/env bash
# Cross-runtime check: does kiln execute the SHIPPED meld-fused core the same way wasmtime does?
#
# WHAT THIS REPLACES. scripts/jess-build.sh ran
#     "$KILND" "$FUSED" --function run-stabilization 2>/dev/null || true
# and reported "kiln check inconclusive (non-gating)" whenever it failed. It failed EVERY time,
# and could not have done otherwise:
#   * the fused core exports no `run-stabilization`. kiln says so plainly —
#     "[Runtime][E07DA] Function not found" — and then LISTS the five exports it does have.
#     meld's fusion renames them to `pulseengine:falcon-cascade/<stage>@0.7.0#<fn>`.
#   * wasmtime's side of the "comparison" invoked that name on a DIFFERENT artifact (the
#     pre-fusion component), so the two halves were never looking at the same thing.
#   * `2>/dev/null || true` then made "kiln disagreed" and "kiln could not run" the same
#     reading — the exact confusion varve#130 recorded as reporting exit 127 as a refusal.
# The JUnit evidence still carried a `kiln-xruntime` testcase whose value was always 0.
#
# WHAT THIS CLAIMS, AND WHAT IT DOES NOT. kiln 0.5.0 (SR-58) can invoke exports on a
# meld-fused CORE module, which is what jess ships. Both engines are driven over the SAME
# artifact, the SAME export and the SAME arguments, and must agree.
#
# It is NOT a value differential, and saying so matters: every cascade export returns an i32
# that is a POINTER into the return area, and that pointer was MEASURED to be constant (9488)
# across three different argument sets. Two engines agreeing on a fixed address is not
# evidence about the arithmetic. What this does establish is that a second, independent engine
# LOADS AND EXECUTES the shipped fused core across all five stage exports without trapping,
# and returns what wasmtime returns. Modest, but true — and it is a real executed result where
# the previous check was a permanently-failing no-op.
#
# Making it a value differential needs kiln to dereference the return area (read N bytes at the
# returned pointer). Filed upstream; until then this check is deliberately labelled down.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
KILND="${KILND:-kilnd}"
MOD="${MOD:-$ROOT/.scratch/invoke/c.loom.wasm}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The export name itself contains colons, so it is NOT safe to pack a field after one.
# A first version wrote "…#mix:4" and split on the FIRST colon, yielding the export name
# "pulseengine" — which then failed as "could not run", correctly, rather than silently
# comparing nothing.
CMP_EXPORT="pulseengine:falcon-cascade/mixer@0.7.0#mix"
ARGS4="0.25 0.5 0.75 0.125"

invoke_kiln() {  # $1 export, rest args -> prints the i32 or nothing
  local e="$1"; shift
  local a=() x
  for x in "$@"; do a+=(--arg "$x"); done
  "$KILND" "$MOD" --invoke "$e" "${a[@]}" 2>&1 | sed -n 's/.*\[0\] i32 \([0-9-]*\).*/\1/p' | head -1
}
invoke_wasmtime() { local e="$1"; shift; wasmtime run --invoke "$e" "$MOD" "$@" 2>/dev/null | tail -1; }

[ -f "$MOD" ] || fail "fused core not found: $MOD"
command -v wasmtime >/dev/null || fail "wasmtime not on PATH"
command -v "$KILND" >/dev/null || [ -x "$KILND" ] \
  || fail "kilnd not found at '$KILND' — that is 'could not run the check', NOT 'the check failed'"

# kilnd must be >= 0.5.0: earlier builds have no --invoke and cannot reach a fused core at all.
kv="$("$KILND" --version 2>&1 | head -1)"
case "$kv" in
  "kilnd "*) : ;;
  *) fail "kilnd does not report a version ('$kv'). Pre-0.5.0 builds print a banner instead and
   have no --invoke, so this check cannot run against them — refusing rather than reporting
   'inconclusive', which is how the previous version hid a permanent failure." ;;
esac
echo "  kiln: $kv"

e="$CMP_EXPORT"
k="$(invoke_kiln "$e" $ARGS4)"
w="$(invoke_wasmtime "$e" $ARGS4)"
# BOTH must produce a value. An empty reading is "could not run"; treating it as agreement is
# precisely the defect being fixed here.
[ -n "$k" ] || fail "kiln produced no value for $e — could not run"
[ -n "$w" ] || fail "wasmtime produced no value for $e — could not run"
[ "$k" = "$w" ] || fail "CROSS-RUNTIME DISAGREEMENT on $e: kiln=$k wasmtime=$w"
echo "  $e -> kiln=$k wasmtime=$w  AGREE"

# And every stage export must at least LOAD AND EXECUTE under kiln. This is the part that is
# genuinely about the shipped artifact rather than about one function.
# Each export is driven with ITS OWN arity. The cascade is not uniform — three distinct
# shapes, measured from the fused module's core signatures:
#   ekf#estimate  (param f32 x6) -> i32      position/attitude/rate #tick (param i32) -> i32
#   mixer#mix     (param f32 x4) -> i32
# A first version passed six zeros to all five, so four of them failed on arity and the count
# read 1/5 — a number that says nothing about the artifact. Passing the wrong arity everywhere
# and then reporting the survivors is the shape of a metric that measures the harness.
n=0; total=0; failed=""
for spec in "ekf@0.7.0#estimate:0 0 0 0 0 0" \
            "position@0.7.0#tick:0" \
            "attitude@0.7.0#tick:0" \
            "mixer@0.7.0#mix:0.25 0.5 0.75 0.125" \
            "rate@0.7.0#tick:0"; do
  stage="${spec%%:*}"; a="${spec#*:}"
  full="pulseengine:falcon-cascade/$stage"
  total=$((total+1))
  if "$KILND" "$MOD" --invoke "$full" $(for x in $a; do printf -- '--arg %s ' "$x"; done) >/dev/null 2>&1
  then n=$((n+1)); else failed="$failed $stage"; fi
done
[ "$n" -eq "$total" ] || fail "kiln executed only $n/$total stage exports; failed:$failed"
echo "  kiln executed $n/$total stage exports of the shipped fused core"
echo "NOTE: agreement is on a return-area POINTER, measured constant across inputs — this is an"
echo "      EXECUTION check, not a value differential (see the header)."
