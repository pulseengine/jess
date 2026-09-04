#!/usr/bin/env bash
# fetch.sh — reconstruct every pinned external artifact from a CLEAN CHECKOUT.
#
# WHY (AFD-064 D4, and AFD-053 S2 before it): tools/deps/artifacts.pins records what the
# jess oracles consume and verifies it by digest, but nothing could PRODUCE those bytes.
# .scratch/ is gitignored, so a fresh clone had the pins and no way to satisfy them — which
# is exactly why the on-target oracles are hand-run evidence rather than a CI gate.
#
# Everything here is verified AFTER fetching, against the digest already in the pins. A
# wrong locator therefore fails loudly instead of silently installing a lookalike; that is
# the whole reason the mapping is expressed as a locator rather than baked into this script.
#
# Usage:  tools/deps/fetch.sh [--force] [--only <substring>]
# Exit:   0 all satisfiable artifacts present+matching | 1 a fetch or digest check failed
#         | 2 nothing to do (refuses to report success over an empty pin set)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PINS="${PINS:-$ROOT/tools/deps/artifacts.pins}"
DEST="${DEST:-$ROOT/.scratch}"
FORCE=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --only)  ONLY="${2:-}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# The host triple the platform-specific pins are expressed against.
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

[ -f "$PINS" ] || fail "no pin file at $PINS"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

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

digest_of() { sha256 "$1"; }

considered=0 fetched=0 skipped=0 already=0

while read -r path want locator rest; do
  case "${path:-}" in ''|'#'*|'['*) continue ;; esac
  [ -n "${want:-}" ] && [ -n "${locator:-}" ] || fail "malformed pin line: $path"
  [ -z "$ONLY" ] || case "$path" in *"$ONLY"*) : ;; *) continue ;; esac
  considered=$((considered+1))

  # The dest path comes from a PR-editable file and this script runs in CI with a token.
  # `../../x` escaped DEST and still reported success (clean-room verification). Confine it.
  case "$path" in
    /*|*..*|*'$('*|*'`'*)
      fail "pin path '$path' escapes the destination tree or contains a substitution — refusing" ;;
  esac

  out="$DEST/$path"

  # A pin may be platform-specific (a compiled binary). Its digest is unsatisfiable on any
  # other host, so SKIP it loudly rather than fetching bytes that can never match.
  # Parse from locator+remainder, matching check.sh exactly. check.sh looked at both while
  # this looked only at `rest`, so a `platform=` placed before the locator made check.sh skip
  # silently while fetch.sh hard-failed — two scripts disagreeing about one file's grammar.
  pin_platform=""
  case "$locator $rest" in *platform=*) pin_platform="${locator} ${rest}"; pin_platform="${pin_platform#*platform=}"; pin_platform="${pin_platform%% *}" ;; esac
  if [ -n "$pin_platform" ] && [ "$pin_platform" != "$HOST_PLATFORM" ]; then
    echo "  skip     $path — pinned for $pin_platform, host is $HOST_PLATFORM"
    skipped=$((skipped+1)); continue
  fi

  if [ "$FORCE" = "0" ] && [ -f "$out" ] && [ "$(digest_of "$out")" = "$want" ]; then
    echo "  present  $path"
    already=$((already+1)); continue
  fi

  mkdir -p "$(dirname "$out")"
  work="$TMP/w"; rm -rf "$work"; mkdir -p "$work"

  case "$locator" in
    release:*)
      spec="${locator#release:}"
      repo="${spec%%@*}"; rest2="${spec#*@}"
      tag="${rest2%%!*}"; tail_="${rest2#*!}"
      asset="${tail_%%!*}"
      member=""; case "$tail_" in *!*) member="${tail_#*!}" ;; esac
      asset="${asset//\{PLATFORM\}/$HOST_PLATFORM}"
      have gh || fail "gh is required to fetch $path"
      echo "  fetch    $path  <- $repo@$tag :: $asset${member:+ :: $member}"
      gh release download "$tag" --repo "$repo" -p "$asset" --dir "$work" --clobber >/dev/null 2>&1 \
        || fail "could not download $asset from $repo@$tag"
      got="$work/$asset"
      [ -f "$got" ] || fail "$asset did not appear after download"
      if [ -n "$member" ]; then
        case "$asset" in
          *.tar.gz|*.tgz) tar xzf "$got" -C "$work" || fail "could not extract $asset" ;;
          *.zip)          unzip -qo "$got" -d "$work" || fail "could not unzip $asset" ;;
          *) fail "don't know how to extract a member from $asset" ;;
        esac
        found="$(find "$work" -type f -name "$member" | head -1)"
        [ -n "$found" ] || fail "member $member not found inside $asset"
        cp "$found" "$out"
      else
        cp "$got" "$out"
      fi
      ;;
    oci:*)
      spec="${locator#oci:}"
      ref="${spec%%!*}"; member="${spec#*!}"
      have oras || fail "oras is required to fetch $path from $ref (brew install oras)"
      echo "  fetch    $path  <- oci $ref :: $member"
      oras pull "$ref" -o "$work" >/dev/null 2>&1 || fail "oras pull failed for $ref"
      found="$(find "$work" -type f -name "$member" | head -1)"
      [ -n "$found" ] || fail "$member not found in OCI artifact $ref"
      cp "$found" "$out"
      ;;
    *) fail "unrecognised locator for $path: $locator" ;;
  esac

  # VERIFY AFTER FETCH. A wrong locator must not leave a plausible file behind.
  got_digest="$(digest_of "$out")"
  if [ "$got_digest" != "$want" ]; then
    rm -f "$out"
    fail "$path digest mismatch after fetch: got ${got_digest:0:16}… want ${want:0:16}… (removed)"
  fi
  fetched=$((fetched+1))
done < "$PINS"

# Refuse to report success over an empty pin set — a fetcher that fetched nothing and
# said "ok" is the same vacuous-green this repo keeps finding in its own checkers.
[ "$considered" -gt 0 ] || { echo "FAIL(2): no pin entries parsed — refusing to report success"; exit 2; }

echo
echo "considered $considered | fetched $fetched | already present $already | skipped (other platform) $skipped"

# Final authority is check.sh, not this script's own bookkeeping — and it must be pointed
# at the directory we actually WROTE TO. Passing no SCRATCH made it verify $ROOT/.scratch
# regardless of DEST, so a fetch into an empty tree was "confirmed" by the pre-existing
# artifacts next door. Caught by running the clean-checkout case and noticing the verify
# passed for the wrong reason.
echo "verifying with check.sh (SCRATCH=$DEST):"
SCRATCH="$DEST" "$ROOT/tools/deps/check.sh"
