#!/usr/bin/env bash
# triage-gate.sh — make the triage-status vocabulary ENFORCED, not advisory.
#
# WHY THIS EXISTS (AFD-062, pulseengine/rivet#885):
#   `rivet validate` reports an out-of-vocabulary field value as a WARNING and
#   exits 0. `rivet add` rejects the SAME value as a hard error. jess's CI gates
#   on `rivet validate`'s exit code, so for months 37 of 61 ai-found-defect
#   artifacts (60%) carried a triage-status the schema disallows and the "core
#   gate" could not go red. This converts that warning into an error.
#
# It is the `--strict` that rivet does not have yet. When rivet#885 ships one,
# this script should be replaced by it, not kept alongside.
#
# THE ALLOWED SET IS READ FROM THE SCHEMA, never hardcoded here — a second copy
# is a second thing to drift.
#
# Usage:  tools/rivet/triage-gate.sh [--self-test]
# Exit:   0 every value in vocabulary | 2 a value is outside it | 3 harness broke
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHEMA="${SCHEMA:-$ROOT/schemas/common.yaml}"
ARTIFACTS="${ARTIFACTS:-$ROOT/artifacts}"

# Non-terminal states: a defect here is still live work. Declared with the
# vocabulary in schemas/common.yaml; kept in sync by the assertion below.
NON_TERMINAL="open scoping confirmed confirmed-upstream reported-upstream filed-upstream"

[ -f "$SCHEMA" ] || { echo "FAIL(3): no schema at $SCHEMA"; exit 3; }
[ -d "$ARTIFACTS" ] || { echo "FAIL(3): no artifacts dir at $ARTIFACTS"; exit 3; }

allowed="$(python3 - "$SCHEMA" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
m=re.search(r'- name: triage-status\b.*?allowed-values:\s*\[(.*?)\]', s, re.S)
if not m:
    sys.stderr.write("could not locate triage-status allowed-values in schema\n"); sys.exit(3)
print(" ".join(v.strip() for v in m.group(1).replace("\n"," ").split(",") if v.strip()))
PY
)" || { echo "FAIL(3): could not read vocabulary from schema"; exit 3; }

[ -n "$allowed" ] || { echo "FAIL(3): vocabulary parsed EMPTY — refusing to pass vacuously"; exit 3; }

# Refuse to pass on an empty corpus: a gate over nothing is not a green gate.
total=$( { grep -rho "triage-status: *[A-Za-z-]*" "$ARTIFACTS" 2>/dev/null || true; } | wc -l | tr -d ' ')
[ "$total" -gt 0 ] || { echo "FAIL(3): found ZERO triage-status fields — gate would be vacuous"; exit 3; }

echo "vocabulary (from $(basename "$SCHEMA")): $allowed"
echo "triage-status fields found: $total"

bad=0
while read -r file val; do
  case " $allowed " in
    *" $val "*) : ;;
    *) echo "  OUT-OF-VOCABULARY: '$val' in $file"; bad=$((bad+1)) ;;
  esac
done < <( { grep -rHo "triage-status: *[A-Za-z-]*" "$ARTIFACTS" 2>/dev/null || true; } \
         | sed 's/:triage-status: */ /' )

# Assert the non-terminal list is itself a subset of the vocabulary — otherwise
# a rename in the schema silently makes a non-terminal state unreachable.
for nt in $NON_TERMINAL; do
  case " $allowed " in
    *" $nt "*) : ;;
    *) echo "FAIL(3): non-terminal state '$nt' is not in the schema vocabulary"; exit 3 ;;
  esac
done

live=0
for nt in $NON_TERMINAL; do
  n=$( { grep -rho "triage-status: *$nt\$" "$ARTIFACTS" 2>/dev/null || true; } | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] && { echo "  live($nt): $n"; live=$((live+n)); }
done
echo "non-terminal (still live) defects: $live"

if [ "$bad" -gt 0 ]; then
  echo "Result: FAIL — $bad triage-status value(s) outside the schema vocabulary"
  exit 2
fi
echo "Result: PASS — all $total triage-status values in vocabulary"
