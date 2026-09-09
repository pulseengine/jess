#!/usr/bin/env bash
# Refuse the ONE combination varve v0.32.1's rotation makes silently fatal:
# a trust root that cannot verify the layer this project is pinned to.
#
# WHY THIS EXISTS. On 2026-09-07 varve rotated the rolling trust root
# (4e771dc6... -> 7d3b892e...). Layers 2026.08.0 .. 2026.09.1 are signed by the OLD
# root; 2026.09.2 will be the first signed by the NEW one. varve's own guidance to a
# consumer pinned below that boundary is: DO NOTHING.
#
# The hazard is that doing the wrong thing looks trivial. The published
# varve-realms.toml is BYTE-IDENTICAL to the one in this repo except for the
# trust-root line — verified, `diff` is empty once that line is masked. So "vendor the
# new realms file" reads as a one-line no-op diff in review, and produces:
#
#     error: manifest signature verification failed: ... No valid signatures
#
# This repo runs an autonomous loop that bumps pins on evidence. A rule that lives only
# in a release note is a rule the loop will not see. This is that rule, executable.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
REALMS="${REALMS:-$ROOT/varve-realms.toml}"
PIN="${PIN:-$ROOT/varve.toml}"

OLD_ROOT=4e771dc62a08be89e3450f8cd807da58ff70af4a4e124ebf2d2b71684cfd9973
NEW_ROOT=7d3b892e6a33c70043becc708e08042e1cef0d54dd5ae6f23d7d4c68de1da1a0
# The boundary is a varve FACT, not a jess preference: the first layer signed by the
# new root. Layers sort lexically here because they are zero-padded YYYY.MM.N.
FIRST_NEW_ROOT_LAYER=2026.09.2

verdict() { # $1=root $2=layer  -> prints OK/FAIL reason, returns 0/1
  local root="$1" layer="$2" era
  if [ "$root" = "$OLD_ROOT" ]; then era=old
  elif [ "$root" = "$NEW_ROOT" ]; then era=new
  else echo "UNKNOWN trust root $root — neither the pre- nor post-rotation value"; return 1; fi
  # String compare is wrong across a component boundary (2026.09.10 vs 2026.09.2), so
  # compare the numeric triple.
  local a b; a=$(printf '%s' "$layer" | awk -F. '{printf "%04d%02d%03d",$1,$2,$3}')
  b=$(printf '%s' "$FIRST_NEW_ROOT_LAYER" | awk -F. '{printf "%04d%02d%03d",$1,$2,$3}')
  if [ "$a" -ge "$b" ]; then
    [ "$era" = new ] && { echo "OK: layer $layer is post-rotation and the realm carries the NEW root"; return 0; }
    echo "FAIL: layer $layer is signed by the NEW root, but this realm carries the OLD one — it cannot verify"; return 1
  else
    [ "$era" = old ] && { echo "OK: layer $layer is pre-rotation and the realm carries the OLD root"; return 0; }
    echo "FAIL: this realm carries the NEW trust root, but layer $layer was signed by the OLD one.
   varve: 'Every layer published from 2026.08.0 through 2026.09.1 was signed by the old
   root and does not verify against the new one.' Taking the realms file WITHOUT moving
   the pin to >= $FIRST_NEW_ROOT_LAYER leaves this project pinned to a layer its own realm
   cannot verify. Until that layer exists, the correct action is to do NOTHING."; return 1
  fi
}

if [ "${1:-}" = "--self-test" ]; then
  ok=0
  # Every row must be OBSERVED to give its stated verdict — including the two failures.
  # A guard whose failing cases were never executed is the vacuity this campaign keeps
  # finding in checkers rather than in code.
  for row in "$OLD_ROOT|2026.08.4|0|pre-rotation pin, old root (the frozen old realm)" \
             "$NEW_ROOT|2026.09.2|0|post-rotation pin, new root (jess today)" \
             "$NEW_ROOT|2026.08.4|1|THE TRAP: new realms file, pin not moved" \
             "$OLD_ROOT|2026.09.2|1|pin moved past the boundary, realm not updated" \
             "deadbeef|2026.08.4|1|unrecognised root"; do
    IFS='|' read -r r l want label <<EOF
$row
EOF
    got=0; out=$(verdict "$r" "$l") || got=1
    if [ "$got" = "$want" ]; then printf "  [ok ] %-42s -> %s\n" "$label" "$(echo "$out" | head -1)"
    else ok=1; printf "  [FAIL] %-42s want rc=%s got rc=%s\n" "$label" "$want" "$got"; fi
  done
  echo "SELF-TEST: $([ $ok = 0 ] && echo PASS || echo FAIL)"; exit $ok
fi

root=$(sed -n 's/^trust-root = "\(.*\)"/\1/p' "$REALMS" | head -1)
layer=$(sed -n 's/^layer[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$PIN" | head -1)
[ -n "$root" ]  || { echo "no trust-root in $REALMS" >&2; exit 2; }
[ -n "$layer" ] || { echo "no layer in $PIN" >&2; exit 2; }
echo "realm trust-root: $root"
echo "pinned layer:     $layer"
out=$(verdict "$root" "$layer"); rc=$?
echo "$out"
exit $rc
