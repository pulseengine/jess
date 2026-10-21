#!/usr/bin/env bash
# Assert the falcon EKF-stage pin names the REAL estimator, falcon-iekf.
#
# WHY THIS EXISTS. From falcon v1.140.0 the components bundle ships TWO components that
# export the SAME interface string, `pulseengine:falcon-cascade/ekf@0.11.0`:
#
#   falcon-iekf   role=flight-core-stage  23,053 B  Invariant-EKF, Kani harnesses run in CI
#   falcon-ekf    role=legacy-stage       14,750 B  LEGACY Mahony attitude filter on SO(3);
#                                                   relay's own manifest says it is "not the
#                                                   estimator the falcon flight core uses"
#
# MEASURED, not read off the prose: `wasm-tools component wit` on both prints the identical
# export line. jess resolves exports with tools/cascade-differential/ifacever.py, which
# matches a version-AGNOSTIC suffix (`ekf#estimate`) by design (AFD-121). That is the right
# behaviour for a version bump and is exactly why it cannot discriminate here: swap the
# locator and every oracle downstream keeps passing, against a Mahony filter, silently.
#
# So the discriminator cannot live downstream. It has to be asserted at the PIN, which is
# the only place the two are still distinguishable — by upstream member name and by digest.
#
# Exit 0 = the ekf-stage pin names falcon-iekf and no pin names the legacy component.
# Exit 1 = a pin names the legacy estimator, or the ekf-stage pin could not be identified.
set -uo pipefail

SELFTEST=0
[ "${1:-}" = "--self-test" ] && SELFTEST=1

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# Overridable so a negative control can run against a VARIANT pin file. A control that has
# to move the real file aside is a control nobody runs (AFD-139: the 1c control set CAT= on
# a script where CAT was not overridable, so it silently tested the real catalogue and
# reported OK).
PINS="${PINS:-$ROOT/tools/deps/artifacts.pins}"

# The dest path the ekf oracles actually consume. Grepped, not assumed:
#   tools/fusion-matrix/run.sh:20, tools/appcompose/build-and-verify.sh:48,
#   hardware/renode/cascade-invoke/build.sh:186 all read $SCRATCH/falcon/iekf.wasm
EKF_DEST="${EKF_DEST:-falcon/iekf.wasm}"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$PINS" ] || fail "$PINS missing"

# Every falcon stage pin, for the DENOMINATOR. A check that says "the ekf pin is correct"
# without saying how many falcon pins it looked at is the AFD-138 shape.
stage_lines=$(grep -E '^falcon/[a-z]+\.wasm[[:space:]]' "$PINS" || true)
nstages=$(printf '%s' "$stage_lines" | grep -c . || true)
[ "$nstages" -gt 0 ] || fail "no falcon stage pins found in $PINS (cannot verify anything)"

ekf_line=$(printf '%s\n' "$stage_lines" | awk -v d="$EKF_DEST" '$1==d')
nekf=$(printf '%s' "$ekf_line" | grep -c . || true)
[ "$nekf" = "1" ] || fail "expected exactly 1 pin for '$EKF_DEST', found $nekf — the estimator pin cannot be identified, so its identity is UNVERIFIED (not 'fine')"

locator=$(printf '%s\n' "$ekf_line" | awk '{print $3}')
member="${locator##*!}"

# Anchored on the member filename. Note `falcon-ekf` is NOT a substring of `falcon-iekf`,
# so a bare grep would pass the legacy case by accident in one direction and fail the real
# one in the other; both patterns are anchored to the leading component name.
case "$member" in
  falcon-iekf-*.wasm) : ;;
  falcon-ekf-*.wasm)  fail "the '$EKF_DEST' pin names the LEGACY Mahony filter ($member). relay's manifest: 'not the estimator the falcon flight core uses'. Downstream cannot detect this — both export ekf@0.11.0." ;;
  *)                  fail "the '$EKF_DEST' pin's upstream member is '$member', which names neither falcon-iekf nor falcon-ekf. Refusing rather than guessing which estimator this is." ;;
esac

# No pin anywhere may name the legacy component: jess has no use for it, so its presence
# would mean a stage was swapped or a second copy introduced.
legacy=$(grep -nE 'falcon-ekf-[0-9v][^[:space:]]*\.wasm' "$PINS" || true)
[ -z "$legacy" ] || fail "a pin names the legacy estimator:"$'\n'"$legacy"

echo "OK: '$EKF_DEST' is pinned to $member (the invariant EKF, role=flight-core-stage)."
echo "    $nstages falcon stage pin(s) present; 1 of $nstages is the estimator and was identity-checked."
echo "    The other $((nstages-1)) carry no iekf/ekf ambiguity (rate, mixer, attitude, position have one upstream component each) — NOT identity-checked, and they do not need to be."

if [ "$SELFTEST" = "1" ]; then
  echo
  echo "--- negative controls (each differs from the real pin in EXACTLY ONE variable) ---"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  me="$ROOT/tools/deps/check-estimator-identity.sh"
  rc_of() { PINS="$1" "$me" >"$tmp/out" 2>&1; echo $?; }

  # NC1 positive control: the real file must PASS, or every red below is meaningless.
  rc=$(rc_of "$PINS"); [ "$rc" = "0" ] && echo "NC1 real pin file         -> PASS (exit 0)   [positive control]" || { echo "NC1 real pin file -> exit $rc, expected 0"; cat "$tmp/out"; exit 1; }

  # NC2: swap ONLY the member name to the legacy component.
  sed 's|falcon-iekf-v1\.\([0-9]*\)\.wasm|falcon-ekf-v1.\1.wasm|' "$PINS" > "$tmp/legacy.pins"
  cmp -s "$PINS" "$tmp/legacy.pins" && { echo "NC2 could not build the variant (the substitution matched nothing) — CONTROL IS VACUOUS"; exit 1; }
  rc=$(rc_of "$tmp/legacy.pins"); [ "$rc" = "1" ] && echo "NC2 locator -> falcon-ekf -> FAIL (exit 1)   [the defect this guard exists for]" || { echo "NC2 expected exit 1, got $rc"; cat "$tmp/out"; exit 1; }

  # NC3: an unrelated member name must also refuse, not pass by default.
  sed 's|falcon-iekf-v1\.\([0-9]*\)\.wasm|falcon-estimator-v1.\1.wasm|' "$PINS" > "$tmp/unknown.pins"
  rc=$(rc_of "$tmp/unknown.pins"); [ "$rc" = "1" ] && echo "NC3 locator -> unknown name -> FAIL (exit 1)   [fails closed, does not guess]" || { echo "NC3 expected exit 1, got $rc"; cat "$tmp/out"; exit 1; }

  # NC4: the ekf pin absent entirely must be distinguishable from 'answered yes'.
  grep -v "^$EKF_DEST[[:space:]]" "$PINS" > "$tmp/missing.pins"
  rc=$(rc_of "$tmp/missing.pins"); [ "$rc" = "1" ] && echo "NC4 ekf pin removed       -> FAIL (exit 1)   ['could not run' is not 'answered no']" || { echo "NC4 expected exit 1, got $rc"; cat "$tmp/out"; exit 1; }

  # NC5: a SECOND pin naming the legacy component, with the real ekf pin left correct.
  { cat "$PINS"; echo "falcon/legacy.wasm            0000000000000000000000000000000000000000000000000000000000000000  release:pulseengine/relay@falcon-v1.140.0!falcon-components-v1.140.tar.gz!falcon-ekf-v1.140.wasm"; } > "$tmp/second.pins"
  rc=$(rc_of "$tmp/second.pins"); [ "$rc" = "1" ] && echo "NC5 legacy added alongside -> FAIL (exit 1)   [the correct ekf pin does not excuse it]" || { echo "NC5 expected exit 1, got $rc"; cat "$tmp/out"; exit 1; }

  echo "all 5 controls behaved as specified (1 positive, 4 negative)"
fi
