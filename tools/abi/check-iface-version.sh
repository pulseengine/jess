#!/usr/bin/env bash
# Every committed site that BAKES the falcon interface version must agree with the version
# the PINNED artifacts actually export.
#
# WHY THIS EXISTS. AFD-121 established the rule: do not hardcode the falcon interface
# version, it moves without the signatures moving. The rule was enforced in exactly ONE leg
# -- tools/cascade-differential/ifacever.py resolves exports version-agnostically for the
# Python/synth path. The component-model leg CANNOT use that trick: WIT imports and WAC
# plug expressions name the version literally, and there is no agnostic form. So that leg
# had no mechanism at all, and nothing said so.
#
# MEASURED COST OF THE GAP (AFD-141): the falcon v1.139 -> v1.140 pin bump (0.10.0 ->
# 0.11.0) left 18 baked sites across 10 files pointing at 0.10.0. CI went green on 8 of 9
# checks; `component oracles` failed at `wac compose` with "the instance has no export named
# pulseengine:falcon-cascade/rate@0.10.0", and steps 10/11/12 of that job were SKIPPED
# rather than run -- so three further oracles were unverified, which is not the same as fine.
# The pin file, the Python leg and every ARM lowering were all correct and silent about it.
#
# Exit 0 = every baked site agrees with the pinned artifacts.
# Exit 1 = a site disagrees  (the dangerous case: composition breaks, or worse, resolves
#                             against a stale interface that happens to still exist)
# Exit 2 = the pinned artifacts are absent, so the expected version COULD NOT BE DERIVED.
#          Deliberately distinct from 1: "could not run" is not "answered no".
set -uo pipefail

SELFTEST=0
[ "${1:-}" = "--self-test" ] && SELFTEST=1

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRATCH="${SCRATCH:-$ROOT/.scratch}"
# Overridable so a control can point at a tree with a deliberately stale site.
TREE="${TREE:-$ROOT}"
REF="${REF:-$SCRATCH/falcon/rate.wasm}"

fail() { echo "FAIL: $*" >&2; exit 1; }

if [ ! -f "$REF" ]; then
  echo "CANNOT DETERMINE: $REF absent, so the expected interface version cannot be derived"
  echo "  fetch it:  tools/deps/fetch.sh --only falcon"
  exit 2
fi
command -v wasm-tools >/dev/null 2>&1 || { echo "CANNOT DETERMINE: wasm-tools not on PATH"; exit 2; }

# Derived from the ARTIFACT, never from a constant in this script -- a hardcoded expectation
# here would be the very defect being checked for, one level up.
want=$(wasm-tools component wit "$REF" 2>/dev/null \
       | grep -oE 'pulseengine:falcon-cascade@[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/.*@//')
[ -n "$want" ] || { echo "CANNOT DETERMINE: no falcon-cascade package version in $REF"; exit 2; }

# Every committed site, found mechanically rather than from a list that was right when typed.
# SCOPE: .wit, .wac and .sh -- the legs where the version is named LITERALLY and no
# agnostic form exists. *.py is deliberately OUT of scope and that is reported below, not
# silently dropped: the Python leg HAS the agnostic mechanism (ifacever.find_export), so a
# version string there is either resolved at runtime or is prose. Measured: the only two
# matches in *.py are a docstring recording an observation about @0.7.0 and an argparse
# --package help example. Flagging documentation as a defect is how a gate earns a `|| true`.
sites=$(cd "$TREE" && grep -rn 'falcon-cascade[/@][a-z-]*@\?[0-9]\+\.[0-9]\+\.[0-9]\+' \
          --include='*.wit' --include='*.wac' --include='*.sh' . 2>/dev/null \
        | grep -v '^\./\.git' | grep -v '^\./\.scratch' | grep -v 'check-iface-version\.sh' || true)
# The uncovered leg, counted so the pass states what it did NOT look at.
pysites=$(cd "$TREE" && grep -rn 'falcon-cascade[/@][a-z-]*@\?[0-9]\+\.[0-9]\+\.[0-9]\+' \
            --include='*.py' . 2>/dev/null | grep -v '^\./\.git' | grep -v '^\./\.scratch' || true)
npy=$(printf '%s' "$pysites" | grep -c . || true)
nsites=$(printf '%s' "$sites" | grep -c . || true)
[ "$nsites" -gt 0 ] || fail "no baked interface-version sites found at all — this check cannot be verifying anything (expected the WIT and WAC files to carry one)"

# PER-MATCH, not per-line. A WAC plug names the interface TWICE on one line
#   "pulseengine:falcon-cascade/rate@0.11.0": r["pulseengine:falcon-cascade/rate@0.11.0"],
# so a line carrying one stale and one correct version CONTAINS the wanted string, and a
# line-level `grep -v "@$want"` filters it out as agreeing. That is exactly how this gate
# would have gone blind on the defect it exists for; NC2 caught it before it shipped.
bad=$(printf '%s\n' "$sites" | awk -v w="$want" '
  { line=$0; n=0;
    s=line;
    while (match(s, /falcon-cascade[\/@][a-z-]*@?[0-9]+\.[0-9]+\.[0-9]+/)) {
      tok=substr(s, RSTART, RLENGTH);
      if (tok !~ ("@" w "$")) n++;
      s=substr(s, RSTART+RLENGTH);
    }
    if (n>0) print line "   [" n " stale occurrence(s) on this line]";
  }' || true)
nbad=$(printf '%s' "$bad" | grep -c . || true)
# Count OCCURRENCES too, so the denominator is the thing actually compared.
nocc=$(printf '%s\n' "$sites" | grep -oE 'falcon-cascade[/@][a-z-]*@?[0-9]+\.[0-9]+\.[0-9]+' | grep -c . || true)
nok=$(printf '%s\n' "$sites" | grep -oE "falcon-cascade[/@][a-z-]*@?$want" | grep -c . || true)

echo "expected interface version $want, derived from $(basename "$REF") (the pinned artifact, not a constant)"
echo "$nsites line(s) in .wit/.wac/.sh checked, carrying $nocc version occurrence(s): $nok at @$want, $((nocc-nok)) stale ($nbad line(s) affected)"
echo "$npy *.py site(s) NOT CHECKED — that leg resolves the version at runtime via"
echo "  ifacever.find_export, so a literal there is prose, not a binding (see SCOPE above)"
if [ "$nbad" -gt 0 ]; then
  printf '%s\n' "$bad" | sed 's/^/  /'
  fail "$nbad site(s) bake an interface version other than $want. WIT and WAC name the version literally — there is no version-agnostic form for this leg (AFD-121 covers only the Python leg), so these must be bumped with the pin."
fi

if [ "$SELFTEST" = "1" ]; then
  echo
  echo "--- controls (each differs from the real tree in EXACTLY ONE variable) ---"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  me="$ROOT/tools/abi/check-iface-version.sh"

  # NC1 positive: the real tree passes, or every red below proves nothing.
  rc=0; TREE="$ROOT" "$me" >"$tmp/o" 2>&1 || rc=$?
  [ "$rc" = "0" ] && echo "NC1 real tree              -> PASS (exit 0)   [positive control]" || { echo "NC1 expected 0, got $rc"; cat "$tmp/o"; exit 1; }

  # NC2: one stale site, in a WAC file. This is the exact shape that broke CI.
  mkdir -p "$tmp/t/tools/appcompose"
  cp -R "$ROOT/wit-deps" "$tmp/t/" 2>/dev/null
  sed "s/@$want/@0.10.0/" "$ROOT/tools/appcompose/compose.wac" > "$tmp/t/tools/appcompose/compose.wac"
  grep -q '@0.10.0' "$tmp/t/tools/appcompose/compose.wac" || { echo "NC2 variant not built — CONTROL IS VACUOUS"; exit 1; }
  rc=0; TREE="$tmp/t" "$me" >"$tmp/o" 2>&1 || rc=$?
  [ "$rc" = "1" ] && echo "NC2 one stale .wac site    -> FAIL (exit 1)   [the defect this gate exists for]" || { echo "NC2 expected 1, got $rc"; cat "$tmp/o"; exit 1; }

  # NC3: missing reference artifact must be exit 2, NOT a pass and NOT conflated with 1.
  rc=0; REF="$tmp/nope.wasm" "$me" >"$tmp/o" 2>&1 || rc=$?
  [ "$rc" = "2" ] && echo "NC3 reference absent       -> CANNOT DETERMINE (exit 2)   ['could not run' kept distinct]" || { echo "NC3 expected 2, got $rc"; cat "$tmp/o"; exit 1; }

  # NC4: a tree with NO baked sites must refuse, not pass vacuously.
  mkdir -p "$tmp/empty"
  rc=0; TREE="$tmp/empty" "$me" >"$tmp/o" 2>&1 || rc=$?
  [ "$rc" = "1" ] && echo "NC4 tree with no sites     -> FAIL (exit 1)   [refuses to pass over nothing]" || { echo "NC4 expected 1, got $rc"; cat "$tmp/o"; exit 1; }

  echo "all 4 controls behaved as specified (1 positive, 3 negative)"
fi
