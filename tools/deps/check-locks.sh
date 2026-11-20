#!/usr/bin/env bash
# Every lockfile jess builds from is committed, current, and free of known advisories.
#
#   check-locks.sh fresh   every tracked Cargo.toml has a tracked Cargo.lock beside it, cargo
#                          accepts each one under --locked, and MODULE.bazel.lock is tracked
#                          and accepted by `bazel mod deps --lockfile_mode=error`
#   check-locks.sh audit   `cargo audit` over EVERY tracked Cargo.lock, not only the top level
#
# Blind spot, measured: --lockfile_mode=error fails only when resolution needs a registry file the
# lock lacks. A MODULE.bazel edit that still resolves to locked versions passes. Downgrading
# bazel_skylib 1.9.0 to 1.8.2 did not fail it, because the graph still selects 1.9.0.
# The set is derived from `git ls-files`, never typed by hand. Each mode prints its denominator.
# Each lock gets one verdict. "could not run" (no network, no tool) is kept apart from "answered
# no".
# Exit 0 = every lock passed. Exit 1 = a lock is missing, stale or has an advisory.
# Exit 2 = could not determine (a tool or the network did not answer).
#
# Why: on 2026-11-20 tools/sigil-gate/sigil-run/Cargo.lock carried 29 advisories, including
# RUSTSEC-2026-0587, while no CI step audited any jess lock. Three sibling repos showed the
# other two gaps that day: a gitignored lock, and CI resolving without --locked.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT" || exit 2
MODE="${1:-}"
case "$MODE" in fresh|audit) ;; *) echo "usage: $0 fresh|audit" >&2; exit 2 ;; esac

bad=0; unknown=0; n=0
verdict() { # $1 = ok|bad|unknown, $2 = what, $3 = detail
  case "$1" in ok) ;; bad) bad=$((bad+1)) ;; *) unknown=$((unknown+1)) ;; esac
  printf '  %-7s %s%s\n' "$1" "$2" "${3:+ — $3}"
}

if [ "$MODE" = fresh ]; then
  command -v cargo >/dev/null || { echo "CANNOT DETERMINE: no cargo"; exit 2; }
  echo "== Cargo manifests: a committed lock, accepted under --locked"
  while IFS= read -r m; do
    n=$((n+1)); d="$(dirname "$m")"
    if ! git ls-files --error-unmatch "$d/Cargo.lock" >/dev/null 2>&1; then
      verdict bad "$d" "no committed Cargo.lock"; continue
    fi
    err="$(cargo metadata --locked --format-version 1 --manifest-path "$m" 2>&1 >/dev/null)"
    if [ $? -eq 0 ]; then verdict ok "$d/Cargo.lock"
    elif printf '%s' "$err" | grep -q -- '--locked was passed'; then
      verdict bad "$d/Cargo.lock" "out of date with $m"
    else
      verdict unknown "$d/Cargo.lock" "cargo metadata failed: $(printf '%s' "$err" | grep -m1 -i error)"
    fi
  done < <(git ls-files '*Cargo.toml')

  echo "== Bazel: MODULE.bazel.lock committed and accepted under --lockfile_mode=error"
  if git ls-files --error-unmatch MODULE.bazel >/dev/null 2>&1; then
    n=$((n+1))
    if ! git ls-files --error-unmatch MODULE.bazel.lock >/dev/null 2>&1; then
      verdict bad MODULE.bazel.lock "not committed"
    elif ! command -v bazel >/dev/null; then
      verdict unknown MODULE.bazel.lock "no bazel on PATH"
    else
      err="$(bazel ${BAZEL_STARTUP_OPTS:-} mod deps --lockfile_mode=error 2>&1 >/dev/null)"
      if [ $? -eq 0 ]; then verdict ok MODULE.bazel.lock
      elif printf '%s' "$err" | grep -qi 'lockfile'; then
        verdict bad MODULE.bazel.lock "out of date: $(printf '%s' "$err" | grep -m1 -i 'lockfile')"
      else
        verdict unknown MODULE.bazel.lock "bazel mod deps failed: $(printf '%s' "$err" | grep -m1 ERROR)"
      fi
    fi
  fi
else
  command -v cargo-audit >/dev/null || { echo "CANNOT DETERMINE: no cargo-audit"; exit 2; }
  echo "== cargo audit over every committed Cargo.lock"
  while IFS= read -r l; do
    n=$((n+1))
    out="$(cargo audit --file "$l" --json 2>/dev/null)"
    c="$(printf '%s' "$out" | jq -r '.vulnerabilities.count // empty' 2>/dev/null)"
    if [ -z "$c" ]; then verdict unknown "$l" "cargo audit gave no parsable report"
    elif [ "$c" = 0 ]; then verdict ok "$l"
    else verdict bad "$l" "$c advisories: $(printf '%s' "$out" | jq -r '[.vulnerabilities.list[] | "\(.advisory.id) \(.package.name) \(.package.version)"] | join(", ")')"
    fi
  done < <(git ls-files '*Cargo.lock')
fi

[ "$n" -gt 0 ] || { echo "CANNOT DETERMINE: zero locks found — that is not a pass"; exit 2; }
echo "$MODE: $n checked, $((n-bad-unknown)) ok, $bad failed, $unknown could not be checked"
[ "$bad" -eq 0 ] || exit 1
[ "$unknown" -eq 0 ] || exit 2
exit 0
