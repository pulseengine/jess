#!/usr/bin/env bash
# Is tools/ladder/input.schema.json byte-identical to pulseengine.eu's schema at the PINNED commit?
#
#   check-schema-pin.sh [<vendored-schema>]
#
# The pin (tools/ladder/schema.pin, a full commit sha) is bumped on purpose, in a reviewed change.
# Comparing against a floating main would turn every upstream schema edit into red CI here.
# Exit 0 = identical. Exit 1 = they differ. Exit 2 = could not fetch the pinned file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VENDORED="${1:-$HERE/input.schema.json}"
PIN="$(tr -d '[:space:]' < "$HERE/schema.pin")"
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || { echo "FAIL: schema.pin is not a full 40-hex commit sha: '$PIN'"; exit 1; }
[ -f "$VENDORED" ] || { echo "FAIL: vendored schema $VENDORED is missing"; exit 1; }
URL="https://raw.githubusercontent.com/pulseengine/pulseengine.eu/$PIN/data/north-star/input.schema.json"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
curl -fsSL --retry 3 -o "$TMP" "$URL" || { echo "CANNOT DETERMINE: could not fetch $URL"; exit 2; }
[ -s "$TMP" ] || { echo "CANNOT DETERMINE: fetched an empty file from $URL"; exit 2; }
if cmp -s "$TMP" "$VENDORED"; then
  echo "OK: $VENDORED is byte-identical to pulseengine.eu@${PIN:0:12} ($(wc -c < "$TMP" | tr -d ' ') bytes)"
  exit 0
fi
echo "FAIL: $VENDORED differs from pulseengine.eu@${PIN:0:12}"
diff "$TMP" "$VENDORED" | head -20
exit 1
