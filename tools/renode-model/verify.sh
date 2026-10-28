#!/usr/bin/env bash
# Verify a packed jess Renode model the way a CONSUMER would (jess#299): unpack it fresh, leave
# the checkout entirely (`cd /`), and run its self-test with nothing but Renode.
#
#   verify.sh <jess-renode-rt1176-<v>.tar.gz>        env: RENODE (default: renode)
#   verify.sh --self-test <good.tar.gz>              1 positive + 5 negative controls
#
# NO HOST PYTHON on the verdict path (maintainer decision on #299, 2026-10-27): no renode-test,
# no Robot Framework. The self-test is rt1176-smoke-check.resc, which asserts the boot line on
# the UART itself and exits non-zero on failure. rt1176-smoke.robot still ships, as an optional
# extra; nothing here runs it.
#
# TWO checks, both required:
#   1. EXACT member set: MODEL.files + LICENSE + renode-model.toml, nothing more, nothing less.
#   2. `renode --console --disable-xwt rt1176-smoke-check.resc`, from cwd /, gives exit 0 AND
#      prints "SMOKE PASS: JESS-RT1176 boot OK". BOTH: measured, Renode exits 0 in ~3 s when the
#      script path does not exist, without loading anything — so exit 0 alone could be a script
#      that never ran. An outer timeout above the script's own 120 s watchdog is the last line of
#      defence against a hang the watchdog could not convert.
#
# Exit 0 = both hold. 1 = a check failed. 2 = could not run (no renode).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
RENODE="${RENODE:-renode}"
PASS_LINE="SMOKE PASS: JESS-RT1176 boot OK"
OUTER=180   # > the .resc's 120 s watchdog
fail() { echo "FAIL: $*"; exit 1; }

verify_one() {
  local tgz="$1" work base root got want rc out
  [ -f "$tgz" ] || fail "no archive at $tgz"
  command -v "$RENODE" >/dev/null 2>&1 || [ -x "$RENODE" ] || { echo "CANNOT RUN: renode not found ($RENODE)"; return 2; }

  work=$(mktemp -d); trap 'rm -rf "$work"' RETURN
  tar xzf "$tgz" -C "$work" || fail "archive does not unpack"
  base=$(ls "$work"); [ "$(printf '%s\n' "$base" | wc -l | tr -d ' ')" = 1 ] || fail "archive must have exactly one top-level directory"
  root="$work/$base"

  # 1. exact member set
  want=$( { grep -vE '^\s*(#|$)' "$ROOT/hardware/renode/MODEL.files" | sed 's/[[:space:]]*#.*//'; echo LICENSE; echo renode-model.toml; } | sort)
  got=$(cd "$root" && find . -type f | sed 's|^\./||' | sort)
  if [ "$got" != "$want" ]; then
    echo "FAIL: archive members are not EXACTLY MODEL.files + LICENSE + renode-model.toml"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^</  missing:/; s/^>/  extra:  /' | grep -E 'missing|extra'
    return 1
  fi
  echo "  1. members: exactly $(printf '%s\n' "$got" | wc -l | tr -d ' ') ($(printf '%s\n' "$want" | wc -l | tr -d ' ') expected)"

  # 2. the self-asserting check, plain Renode, from /
  # stdin from /dev/null: deterministic. With a terminal on stdin, a failed command would leave
  # Renode idling until the .resc's watchdog (still exit 4, but 120 s later); with stdin at end of
  # input it exits at once and the .resc's ProcessExit guard turns that into exit 4.
  ( cd / && perl -e "alarm $OUTER; exec @ARGV" "$RENODE" --console --disable-xwt "$root/rt1176-smoke-check.resc" ) </dev/null > "$work/check.log" 2>&1
  rc=$?
  out=$(perl -pe 's/\e\[[0-9;]*m//g' "$work/check.log" | grep -oE 'SMOKE (PASS|FAIL)[^\r]*' | head -1)
  pkill -9 -f "$root/rt1176-smoke-check.resc" 2>/dev/null || true
  if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "$PASS_LINE"; then
    echo "  2. rt1176-smoke-check.resc from cwd /, plain Renode: exit 0 and '$PASS_LINE'"
    return 0
  fi
  case "$rc" in
    0)   fail "exit 0 but NO '$PASS_LINE' line — the check may never have run (exit 0 alone is not a pass)";;
    3)   fail "the model ran but the boot line did not appear (exit 3): $out";;
    4)   fail "the check exited or timed out before reaching a verdict (exit 4): $out";;
    142) fail "renode hung past the outer ${OUTER}s timeout — even the watchdog did not end it";;
    *)   fail "unexpected exit $rc: ${out:-no SMOKE line}";;
  esac
}

if [ "${1:-}" = "--self-test" ]; then
  good="${2:?--self-test needs the good archive}"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  me="$ROOT/tools/renode-model/verify.sh"
  mutate() {   # mutate <out.tgz> <python snippet operating on dir d> — repacks with plain tar (a control)
    rm -rf "$tmp/m"; mkdir -p "$tmp/m"; tar xzf "$good" -C "$tmp/m"; d="$tmp/m/$(ls "$tmp/m")"
    python3 -c "import os,sys; d=sys.argv[1]; $2" "$d"; tar czf "$1" -C "$tmp/m" .
  }
  ctl() { rc=0; RENODE="$RENODE" "$me" "$1" > "$tmp/o" 2>&1 || rc=$?; echo $rc; }
  r=$(ctl "$good"); [ "$r" = 0 ] && echo "NC0 the real archive                         -> PASS (exit 0)  [positive control]" || { echo "NC0 expected 0 got $r"; cat "$tmp/o"; exit 1; }
  mutate "$tmp/nc1.tgz" "p=d+'/rt1176-smoke-check.resc'; s=open(p).read().replace('JESS-RT1176 boot OK\" \"','JESS-RT1176 NEVER PRINTED\" \"'); open(p,'w').write(s)"
  r=$(ctl "$tmp/nc1.tgz"); [ "$r" = 1 ] && grep -q 'exit 3' "$tmp/o" && echo "NC1 check asserts a line never printed       -> FAIL, exit 3  [the assertion inside the .resc bites]" || { echo "NC1 expected an exit-3 failure, got rc=$r"; cat "$tmp/o"; exit 1; }
  mutate "$tmp/nc2.tgz" "p=d+'/rt1176-smoke-check.resc'; s=open(p).read().replace('\$ORIGIN/','@hardware/renode/'); open(p,'w').write(s)"
  r=$(ctl "$tmp/nc2.tgz"); [ "$r" = 1 ] && grep -q 'exit 4' "$tmp/o" && echo "NC2 check with the OLD repo-root paths       -> FAIL, exit 4  [the defect #299 fixes is observable; NOT a silent exit 0]" || { echo "NC2 expected an exit-4 failure, got rc=$r"; cat "$tmp/o"; exit 1; }
  mutate "$tmp/nc3.tgz" "os.remove(d+'/pixhawk6xrt.repl')"
  r=$(ctl "$tmp/nc3.tgz"); [ "$r" = 1 ] && grep -q 'missing' "$tmp/o" && echo "NC3 a listed file missing                    -> FAIL at check 1" || { echo "NC3 expected 1 got $r"; cat "$tmp/o"; exit 1; }
  mutate "$tmp/nc4.tgz" "open(d+'/stray.bin','w').write('x')"
  r=$(ctl "$tmp/nc4.tgz"); [ "$r" = 1 ] && grep -q 'extra' "$tmp/o" && echo "NC4 an extra unlisted file                   -> FAIL at check 1  [exact set, not membership]" || { echo "NC4 expected 1 got $r"; cat "$tmp/o"; exit 1; }
  mutate "$tmp/nc5.tgz" "os.remove(d+'/LICENSE')"
  r=$(ctl "$tmp/nc5.tgz"); [ "$r" = 1 ] && grep -q 'LICENSE' "$tmp/o" && echo "NC5 LICENSE missing                          -> FAIL at check 1" || { echo "NC5 expected 1 got $r"; cat "$tmp/o"; exit 1; }
  echo "all 6 controls behaved as specified (1 positive, 5 negative)"
  exit 0
fi

verify_one "${1:?usage: verify.sh <archive.tar.gz> | --self-test <good.tar.gz>}"
