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
#
# --only/--exclude exist for RELEASE-WATCH: testing a candidate toolchain means deliberately
# running one artifact off-pin. Excluding it must be an explicit, visible act — never a
# silent skip — so the caller states which pin it is setting aside and why.
set -uo pipefail
ONLY=""; EXCLUDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only)    ONLY="${2:-}"; shift ;;
    --exclude) EXCLUDE="${2:-}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
# Overridable, as in fetch.sh. Without this the two scripts disagree about their own
# interface, and a pin-file variant cannot be tested without moving the real file aside.
PINS="${PINS:-$ROOT/tools/deps/artifacts.pins}"
SCRATCH="${SCRATCH:-$ROOT/.scratch}"

# A pin may be platform-specific (a compiled binary has a different digest per host). Such
# a line carries `platform=<triple>` and is acted on ONLY when it matches the running host;
# the others are skipped visibly. Without this, a linux pin reads as ABSENT on macOS and
# vice versa, which is what kept the on-target oracles out of CI (AFD-064 D4).
# HOST_PLATFORM may be overridden to EXERCISE another platform's pin from this host. That
# is not a convenience: it is how the linux pin gets proven correct before CI depends on it,
# without waiting for a red CI run to discover a typo'd digest.
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64)  HOST_PLATFORM="aarch64-apple-darwin" ;;
  Darwin/x86_64) HOST_PLATFORM="x86_64-apple-darwin" ;;
  Linux/aarch64) HOST_PLATFORM="aarch64-unknown-linux-gnu" ;;
  Linux/x86_64)  HOST_PLATFORM="x86_64-unknown-linux-gnu" ;;
  *)             HOST_PLATFORM="unknown" ;;
esac
HOST_PLATFORM="${HOST_PLATFORM_OVERRIDE:-$HOST_PLATFORM}"
# sha256 helper. macOS ships `shasum` (perl); Linux ships `sha256sum` and only has `shasum`
# if perl happens to be installed. Hardcoding either one makes this script fail on the other
# platform for a reason that has nothing to do with the artifacts — and this file is about to
# run on a linux CI runner.
if command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" 2>/dev/null | cut -d" " -f1; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" 2>/dev/null | cut -d" " -f1; }
else
  echo "FAIL: neither shasum nor sha256sum is available" >&2; exit 1
fi

[ -f "$PINS" ] || { echo "FAIL: $PINS missing" >&2; exit 1; }

# Every platform triple that may legitimately appear in a pin. An UNRECOGNISED triple is a
# typo, and a typo silently removes that pin from verification on EVERY host while this
# script stays green — clean-room verification demonstrated `aarch64-apple-darwinn` doing
# exactly that. Validate rather than trust.
KNOWN_PLATFORMS="aarch64-apple-darwin x86_64-apple-darwin aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu"

miss=0; bad=0; ok=0; skipped=0
# Paths that have at least one line, and whether any line APPLIED to this host. A path whose
# every line is foreign-platform is a COVERAGE GAP, not a skip: nothing verifies it here.
seen_paths=""; covered_paths=""
while read -r path want src rest; do
  case "${path:-}" in ''|'#'*|'['*) continue ;; esac
  pin_platform=""
  case "${src:-} ${rest:-}" in *platform=*) pin_platform="${src} ${rest}"; pin_platform="${pin_platform#*platform=}"; pin_platform="${pin_platform%% *}" ;; esac
  if [ -n "$pin_platform" ]; then
    case " $KNOWN_PLATFORMS " in
      *" $pin_platform "*) : ;;
      *) echo "FAIL: pin '$path' declares an UNKNOWN platform '$pin_platform'." >&2
         echo "A misspelt triple matches no host, so the pin is silently never verified anywhere." >&2
         exit 1 ;;
    esac
  fi
  case " $seen_paths " in *" $path "*) : ;; *) seen_paths="$seen_paths $path" ;; esac
  if [ -n "$pin_platform" ] && [ "$pin_platform" != "$HOST_PLATFORM" ]; then
    printf '  skip     %-32s  pinned for %s, host is %s\n' "$path" "$pin_platform" "$HOST_PLATFORM"
    skipped=$((skipped+1)); continue
  fi
  case " $covered_paths " in *" $path "*) : ;; *) covered_paths="$covered_paths $path" ;; esac
  [ -z "$ONLY" ]    || case "$path" in *"$ONLY"*) : ;; *) continue ;; esac
  if [ -n "$EXCLUDE" ]; then
    case "$path" in *"$EXCLUDE"*) printf '  EXCLUDED %-32s  (caller set this pin aside)\n' "$path"; continue ;; esac
  fi
  f="$SCRATCH/$path"
  if [ ! -f "$f" ]; then
    printf '  ABSENT   %-32s  %s\n' "$path" "$src"; miss=$((miss+1)); continue
  fi
  got="$(sha256 "$f")"
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
# A path every one of whose lines was skipped is NOT verified on this host. Reporting green
# over it would mean an arbitrary binary could sit at that path unchecked — clean-room
# verification did exactly that with /bin/ls after deleting the host's meld line.
uncovered=""
for pth in $seen_paths; do
  case " $covered_paths " in *" $pth "*) : ;; *) uncovered="$uncovered $pth" ;; esac
done
if [ -n "$uncovered" ]; then
  echo "FAIL: no pin line applies to this host ($HOST_PLATFORM) for:$uncovered" >&2
  echo "Those paths are therefore verified by NOTHING here. Add a pin line for this platform." >&2
  exit 1
fi

# Refuse to report a green on an empty pin file.
[ "$ok" -gt 0 ] || { echo "FAIL: no pins were checked — an empty verification is not a pass" >&2; exit 1; }
echo "all $ok pinned artifact(s) present and matching${skipped:+ ($skipped skipped for other platforms)}"
