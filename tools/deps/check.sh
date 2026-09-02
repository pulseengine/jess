#!/usr/bin/env bash
# Verify every external artifact the jess oracles consume against tools/deps/artifacts.pins.
#
# AFD-053 S2: the oracles all defaulted to paths under .scratch/, which is gitignored, and
# NOTHING pinned what was supposed to be there. "against shipped gale-nano 0.7.0" and
# "10/10 digests verified" were asserted by filename and prose. This makes them checkable,
# and makes a clean checkout able to say precisely what it is missing rather than failing
# somewhere deep inside a fusion.
#
# Exit 0 = every pinned artifact present AND matching.
# Exit 1 = a present artifact does NOT match its pin  (the dangerous case: a lookalike)
# Exit 2 = an artifact is absent                      (the honest case: fetch it)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PINS="$ROOT/tools/deps/artifacts.pins"
SCRATCH="${SCRATCH:-$ROOT/.scratch}"
[ -f "$PINS" ] || { echo "FAIL: $PINS missing" >&2; exit 1; }

miss=0; bad=0; ok=0
while read -r path want src; do
  case "${path:-}" in ''|'#'*|'['*) continue ;; esac
  f="$SCRATCH/$path"
  if [ ! -f "$f" ]; then
    printf '  ABSENT   %-32s  %s\n' "$path" "$src"; miss=$((miss+1)); continue
  fi
  got="$(shasum -a 256 "$f" | cut -d' ' -f1)"
  if [ "$got" = "$want" ]; then
    printf '  ok       %-32s  %s\n' "$path" "${want:0:16}…"; ok=$((ok+1))
  else
    printf '  MISMATCH %-32s  pinned %s… got %s…\n' "$path" "${want:0:16}" "${got:0:16}"; bad=$((bad+1))
  fi
done < "$PINS"

echo
if [ "$bad" -gt 0 ]; then
  echo "FAIL: $bad artifact(s) present but NOT matching their pin." >&2
  echo "A lookalike is worse than a missing file: it produces results that look reproducible" >&2
  echo "and are not. Do not report anything measured against these." >&2
  exit 1
fi
if [ "$miss" -gt 0 ]; then
  echo "INCOMPLETE: $ok verified, $miss absent. Fetch them (see the 'source' column) into" >&2
  echo "\$SCRATCH at the paths above, then re-run. The oracles will not be reproducible until then." >&2
  exit 2
fi
# Refuse to report a green on an empty pin file.
[ "$ok" -gt 0 ] || { echo "FAIL: no pins were checked — an empty verification is not a pass" >&2; exit 1; }
echo "all $ok pinned artifact(s) present and matching"
