#!/usr/bin/env bash
# pinver — print the VERSION a pinned artifact was fetched at, read from its own locator.
#
# WHY THIS EXISTS (AFD-122, and now AFD-124). Oracle output lines named their supplier version
# from a hardcoded string. TEST-PIX-032 printed `rate@0.7.0#tick` while PASSING over an
# all-@0.10.0 image, and tools/dispatch/run.sh printed "gale-nano 0.7.0's poll-round drains..."
# while running 0.9.0. A green board that names the wrong version is the drifted-mirror hazard
# (AFD-104) at its smallest scale: a second copy of a fact with nothing keeping it honest.
#
# The locator in artifacts.pins ALREADY carries the version, and the digest check makes it
# load-bearing — a wrong locator cannot produce matching bytes. So it is the one place the
# version can be read from rather than repeated.
#
#   pinver galenano/gale-nano.wasm   ->  0.9.0
#
# REFUSES rather than guessing: an unparseable or missing locator exits 1 with the line it saw.
# A caller that wants to degrade gracefully should print NO version, never a stale one.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PINS="${PINS:-$ROOT/tools/deps/artifacts.pins}"

pinver() {
  local path="$1" line loc v
  line="$(awk -v p="$path" '$1==p{print; exit}' "$PINS")"
  [ -n "$line" ] || { echo "pinver: no pin entry for '$path' in $PINS" >&2; return 1; }
  loc="$(printf '%s\n' "$line" | awk '{print $3}')"
  # oci:...:<ver>!member   |   release:owner/repo@<tag>!...
  v="$(printf '%s\n' "$loc" | sed -n 's|^oci:[^!]*:\([0-9][0-9A-Za-z.+-]*\)!.*|\1|p')"
  [ -n "$v" ] || v="$(printf '%s\n' "$loc" | sed -n 's|^release:[^@]*@\([^!]*\)!.*|\1|p')"
  [ -n "$v" ] || { echo "pinver: cannot parse a version from locator: $loc" >&2; return 1; }
  printf '%s\n' "$v"
}

if [ "${1:-}" = "--self-test" ]; then
  fail=0
  # Positive: both locator shapes resolve.
  got="$(pinver galenano/gale-nano.wasm)" || fail=1
  case "$got" in [0-9]*) echo "  oci locator      -> $got  OK";; *) echo "  oci locator      -> '$got' FAIL"; fail=1;; esac
  got="$(pinver falcon/rate.wasm)" || fail=1
  case "$got" in falcon-v*) echo "  release locator  -> $got  OK";; *) echo "  release locator  -> '$got' FAIL"; fail=1;; esac
  # NEGATIVE CONTROLS — it must REFUSE, not return something plausible. A helper that
  # silently prints nothing would let a caller interpolate an empty version into evidence.
  if pinver no/such/artifact.wasm >/dev/null 2>&1; then echo "  NC1 FAIL: a missing pin did not refuse"; fail=1
  else echo "  NC1 ok: a missing pin refuses"; fi
  t=$(mktemp); printf 'bogus/x.wasm deadbeef  notalocator\n' > "$t"
  if PINS="$t" pinver bogus/x.wasm >/dev/null 2>&1; then echo "  NC2 FAIL: an unparseable locator did not refuse"; fail=1
  else echo "  NC2 ok: an unparseable locator refuses"; fi
  rm -f "$t"
  echo "pinver self-test: $([ $fail -eq 0 ] && echo PASS || echo FAIL)"
  exit $fail
fi

[ $# -eq 1 ] || { echo "usage: pinver.sh <pinned-path> | --self-test" >&2; exit 2; }
pinver "$1"
