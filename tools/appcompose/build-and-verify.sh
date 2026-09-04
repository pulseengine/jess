#!/usr/bin/env bash
# Build the jess flight application, compose the FULL wasm stack, run it, and check
# the result against an independently-computed reference.
#
# This is the oracle for AFD-043 (the missing application seam). It is written as a
# DIFFERENTIAL rather than a golden value, but WITH A CORRECTED CLAIM about what that
# buys. The two legs differ in their COMPOSITION AND ABI PATH — component model + wac +
# gale's gust:os on one side, fused core module + raw canonical-ABI pointers on the
# other. They do NOT differ in their ARITHMETIC: clean-room verification disassembled
# both and found the rate#tick bodies instruction-identical apart from a uniform data
# rebase. So this oracle catches composition, lowering and ABI-marshalling faults, and
# CANNOT catch a bug inside falcon itself — both sides would share it. The earlier
# header claimed the opposite; that claim was wrong.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
OUT="${OUT:-$ROOT/.scratch/appcompose}"
PY="${PY:-python3}"
# DERIVED, not supplied. This defaulted to .scratch/v1341/casc_new.loom.wasm — a file with
# no pin, no locator and no derivation: it existed only on the machine where it was once
# produced, so this oracle had NEVER been reproducible from a clean checkout, and CI found
# that the moment the job ran (AFD-075). It is also not the module build.sh derives: 35
# functions / 15,979 B of code versus 31 / 15,926, so its provenance does not match the
# current pinned toolchain either.
#
# Now fused from the DIGEST-PINNED stage components on demand. MELD/LOOM are overridable in
# the same shape as hardware/renode/cascade-invoke/build.sh so release-watch can swap them.
SCRATCH="${SCRATCH:-$ROOT/.scratch}"
MELD="${MELD:-}"
LOOM="${LOOM:-}"
run_meld() { if [ -n "$MELD" ]; then "$MELD" "$@"; else varve run meld "$@"; fi; }
run_loom() { if [ -n "$LOOM" ]; then "$LOOM" "$@"; else varve run loom "$@"; fi; }
FUSED="${FUSED:-$OUT/fused.loom.wasm}"
mkdir -p "$OUT"

say() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Preflight. The upstream components are NOT vendored in jess (they are supplier
# artifacts, fetched via the DD-026 OCI path). Say so explicitly rather than dying
# on a bare `cp: no such file`, which reads like a jess bug when it is a missing input.
RATE="$SCRATCH/v1341/rate.wasm"
MIXER="$SCRATCH/v1341/mixer.wasm"
NANO="$SCRATCH/galenano7/gale-nano-0.7.0.wasm"
# Derive the fused core if the caller did not supply one. Done BEFORE the preflight so the
# preflight checks a file that can actually exist rather than reporting a derived artifact as
# a missing "supplier artifact" — which is what the old message said, and it was wrong.
if [ ! -f "$FUSED" ]; then
  for st in rate mixer attitude position iekf; do
    [ -f "$SCRATCH/v1341/$st.wasm" ] || { printf 'MISSING PINNED COMPONENT: %s\n' "$SCRATCH/v1341/$st.wasm" >&2; printf 'Run tools/deps/fetch.sh first.\n' >&2; exit 2; }
  done
  run_meld fuse "$SCRATCH"/v1341/{rate,mixer,attitude,position,iekf}.wasm \
      --memory shared --pack-rebase -o "$OUT/fused.wasm" >"$OUT/meld.log" 2>&1 \
      || { echo "FAIL: meld fuse (see $OUT/meld.log)" >&2; exit 1; }
  run_loom optimize "$OUT/fused.wasm" -o "$FUSED" >"$OUT/loom.log" 2>&1 \
      || { echo "FAIL: loom optimize (see $OUT/loom.log)" >&2; exit 1; }
fi

missing=0
for f in "$RATE" "$MIXER" "$NANO" "$FUSED"; do
  [ -f "$f" ] || { printf 'MISSING UPSTREAM ARTIFACT: %s\n' "$f" >&2; missing=1; }
done
if [ "$missing" = 1 ]; then
  cat >&2 <<'MSG'

These are supplier artifacts (relay falcon v1.134.1, gale-nano 0.7.0), not jess
sources, so they are not in git. Fetch them via the DD-026 OCI consumption path
before running this oracle.
MSG
  exit 2
fi

for t in cargo wasm-tools wac wasmtime; do
  command -v "$t" >/dev/null || fail "required tool not on PATH: $t"
done

# The reference driver needs the wasmtime PYTHON module, which is a separate thing from
# the wasmtime CLI checked above. Omitting this check made the script exit 1 on a clean
# machine with a bare ModuleNotFoundError from inside step 5 — after the composition had
# already succeeded, so the failure looked like an oracle mismatch rather than a missing
# dependency. See tools/cascade-differential/requirements.txt.
"$PY" -c 'import wasmtime' 2>/dev/null || fail \
  "the Python module 'wasmtime' is missing for interpreter: $PY
   install it:  $PY -m pip install -r $ROOT/tools/cascade-differential/requirements.txt
   or point PY= at an interpreter that has it"

say "== 1. build the two jess components =="
for c in flight-app gust-hal-stub; do
  ( cd "$ROOT/app/$c" && cargo build --release --target wasm32-unknown-unknown )
  core="$ROOT/app/$c/target/wasm32-unknown-unknown/release/$(echo "jess_$c" | tr - _).wasm"
  [ -f "$core" ] || fail "core module not produced for $c"
  wasm-tools component new "$core" -o "$ROOT/app/$c/$c.wasm"
  cp "$ROOT/app/$c/$c.wasm" "$OUT/"
done

say "== 2. publish gate (jess holds ITSELF to the gate it asks suppliers to pass) =="
"$ROOT/tools/publish-gate/check-consumable.sh" "$OUT/flight-app.wasm" "$OUT/gust-hal-stub.wasm" \
  || fail "jess's own components are not consumable"

say "== 3. compose =="
# the .wac graphs are REPO files, not scratch: $OUT is gitignored, so a fresh clone
# would otherwise reach this line with no composition graph and fail confusingly.
cp "$ROOT/tools/appcompose/compose.wac" "$ROOT/tools/appcompose/compose2.wac" "$OUT/"
cp "$RATE" "$MIXER" "$OUT/"
cp "$NANO" "$OUT/gale-nano.wasm"
( cd "$OUT"
  wac compose --dep gust:runtime=gale-nano.wasm --dep pulseengine:rate=rate.wasm \
      --dep pulseengine:mixer=mixer.wasm --dep jess:flight-app=flight-app.wasm \
      compose.wac -o step1.wasm
  wac compose --dep jess:hal=gust-hal-stub.wasm --dep jess:step1=step1.wasm \
      compose2.wac -o full.wasm )
wasm-tools validate "$OUT/full.wasm" || fail "composed image does not validate"

say "== 4. RUN the composed image =="
got="$(wasmtime run --invoke 'run()' "$OUT/full.wasm" | tail -1)"
lo=$(( got & 0x7fffffff )); hi=$(( (got >> 31) & 1 ))
say "   returned $got  ->  falcon fold=$lo  clock-live=$hi"
[ "$hi" = "1" ] || fail "clock leg inert — gale's deadline() did not act on our argument"

say "== 5. independent reference + negative control =="
ref_out="$("$PY" "$ROOT/tools/cascade-differential/cascade_ref.py" "$FUSED")" || fail "reference driver failed (this includes its own negative control)"
printf '%s\n' "$ref_out" | sed 's/^/   /'
want="$(printf '%s\n' "$ref_out" | sed -n 's/.*EXPECTED FOLDED u32 (low 31 bits): //p')"
[ -n "$want" ] || fail "could not parse the reference value"
[ "$lo" = "$want" ] || fail "DIFFERENTIAL MISMATCH: composed=$lo reference=$want"

say
say "PASS — composed image and independent reference agree ($lo), clock leg live,"
say "       and the reference's own negative control showed the fold tracks its input."
