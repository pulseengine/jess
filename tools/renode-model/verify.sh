#!/usr/bin/env bash
# Verify a packed jess Renode model the way a CONSUMER would (jess#299): unpack it fresh, leave
# the checkout entirely (`cd /`), and require the model to boot.
#
#   verify.sh <jess-renode-rt1176-<v>.tar.gz>        env: RENODE, RENODE_TEST
#   verify.sh --self-test <good.tar.gz>              runs 1 positive + 4 negative controls
#
# THREE checks, all required:
#   1. EXACT member set: MODEL.files + LICENSE + renode-model.toml, nothing more, nothing less.
#      Membership alone ("the files we need are in there") would pass an archive that also
#      carries an untracked experiment or a stray binary.
#   2. renode-test on the unpacked robot suite, from cwd /, must pass (the check #299 names).
#   3. The unpacked rt1176-smoke.resc, run headless from cwd /, must print the boot line.
#
# WHY (3) AS WELL AS (2). The robot suite resolves paths with ${CURDIR}, so it passes even if the
# .resc still had repo-root-relative paths — the exact defect #299 asked to fix. Measured
# 2026-10-27: the pre-fix .resc run from / fails with "Could not find file
# 'hardware/renode/pixhawk6xrt.repl'" while the robot would still be green. A check that only
# runs the robot cannot see the property it is supposed to protect. Self-test NC1 proves (3) can.
#
# Exit 0 = all three hold. 1 = a check failed. 2 = could not run (no renode / renode-test).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
RENODE="${RENODE:-renode}"; RENODE_TEST="${RENODE_TEST:-renode-test}"
UART_OK="JESS-RT1176 boot OK"
fail() { echo "FAIL: $*"; exit 1; }

verify_one() {
  local tgz="$1" work base root got want
  [ -f "$tgz" ] || fail "no archive at $tgz"
  command -v "$RENODE" >/dev/null 2>&1 || [ -x "$RENODE" ] || { echo "CANNOT RUN: renode not found ($RENODE)"; return 2; }
  command -v "$RENODE_TEST" >/dev/null 2>&1 || [ -x "$RENODE_TEST" ] || { echo "CANNOT RUN: renode-test not found ($RENODE_TEST)"; return 2; }

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

  # 2. the robot suite, from /
  # cwd is / so nothing in the MODEL can resolve against a checkout — that is what #299's `cd /`
  # is for. renode-test's own results go to a temp dir: by default it writes them into the cwd,
  # and / is read-only on macOS and not writable by the `runner` user on a GitHub runner, so a
  # literal `cd / && renode-test …` fails for a reason that says nothing about the model.
  # Measured: "Opening output file '/results-rt1176-smoke.robot.xml' failed: Read-only file system".
  mkdir -p "$work/results"
  if ! ( cd / && "$RENODE_TEST" -r "$work/results" "$root/rt1176-smoke.robot" ) > "$work/robot.log" 2>&1; then
    # A renode-test that cannot START (its Python deps are absent) says nothing about the model.
    # Reporting it as a model failure would be "could not run" passed off as "answered no" —
    # found the first time this script ran, on a host without robotframework installed.
    if grep -qE "No module named|Please install required dependencies|Opening output file .* failed" "$work/robot.log"; then
      echo "CANNOT RUN: renode-test could not start or could not write its results (an environment fault, not a model result):"; sed 's/^/    /' "$work/robot.log" | head -3
      return 2
    fi
    tail -15 "$work/robot.log"; fail "renode-test on the unpacked robot suite failed (cwd /)"
  fi
  echo "  2. renode-test rt1176-smoke.robot from cwd /: passed"

  # 3. the .resc, from /, headless; poll for the boot line rather than sleeping a fixed time
  ( cd / && "$RENODE" --console --disable-xwt -e "include @$root/rt1176-smoke.resc" > "$work/resc.log" 2>&1 & echo $! > "$work/pid" )
  local i=0 ok=0
  while [ $i -lt 60 ]; do
    perl -pe 's/\e\[[0-9;]*m//g' "$work/resc.log" 2>/dev/null | grep -q "$UART_OK" && { ok=1; break; }
    perl -pe 's/\e\[[0-9;]*m//g' "$work/resc.log" 2>/dev/null | grep -q 'Could not find file' && break
    sleep 0.5; i=$((i+1))
  done
  kill "$(cat "$work/pid")" 2>/dev/null; sleep 0.5; kill -9 "$(cat "$work/pid")" 2>/dev/null
  if [ $ok != 1 ]; then
    perl -pe 's/\e\[[0-9;]*m//g' "$work/resc.log" | grep -iE 'error|could not' | head -3 | sed 's/^/    /'
    fail "the unpacked rt1176-smoke.resc did not print '$UART_OK' when run from cwd /"
  fi
  echo "  3. rt1176-smoke.resc from cwd /: printed '$UART_OK'"
  return 0
}

if [ "${1:-}" = "--self-test" ]; then
  good="${2:?--self-test needs the good archive}"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  me="$ROOT/tools/renode-model/verify.sh"
  mutate() {   # mutate <out.tgz> <python snippet operating on dir d>
    rm -rf "$tmp/m"; mkdir -p "$tmp/m"; tar xzf "$good" -C "$tmp/m"; d="$tmp/m/$(ls "$tmp/m")"
    python3 -c "import os,sys; d=sys.argv[1]; $2" "$d"; tar czf "$1" -C "$tmp/m" .  # plain tar is fine for a control
  }
  ctl() { rc=0; RENODE="$RENODE" RENODE_TEST="$RENODE_TEST" "$me" "$1" > "$tmp/o" 2>&1 || rc=$?; echo $rc; }
  r=$(ctl "$good"); [ "$r" = 0 ] && echo "NC0 the real archive                      -> PASS (exit 0)  [positive control]" || { echo "NC0 expected 0 got $r"; cat "$tmp/o"; exit 1; }
  mutate "$tmp/nc1.tgz" "p=d+'/rt1176-smoke.resc'; s=open(p).read().replace('\$ORIGIN/','@hardware/renode/'); open(p,'w').write(s)"
  r=$(ctl "$tmp/nc1.tgz"); [ "$r" = 1 ] && grep -q 'rt1176-smoke.resc did not print' "$tmp/o" && echo "NC1 .resc with the OLD repo-root paths     -> FAIL at check 3  [the defect #299 fixes is observable]" || { echo "NC1 expected a check-3 failure, got rc=$r"; cat "$tmp/o"; exit 1; }
  mutate "$tmp/nc2.tgz" "os.remove(d+'/pixhawk6xrt.repl')"
  r=$(ctl "$tmp/nc2.tgz"); [ "$r" = 1 ] && grep -q 'missing' "$tmp/o" && echo "NC2 a listed file missing                  -> FAIL at check 1" || { echo "NC2 expected 1 got $r"; cat "$tmp/o"; exit 1; }
  mutate "$tmp/nc3.tgz" "open(d+'/stray.bin','w').write('x')"
  r=$(ctl "$tmp/nc3.tgz"); [ "$r" = 1 ] && grep -q 'extra' "$tmp/o" && echo "NC3 an extra unlisted file                 -> FAIL at check 1  [exact set, not membership]" || { echo "NC3 expected 1 got $r"; cat "$tmp/o"; exit 1; }
  mutate "$tmp/nc4.tgz" "os.remove(d+'/LICENSE')"
  r=$(ctl "$tmp/nc4.tgz"); [ "$r" = 1 ] && grep -q 'LICENSE' "$tmp/o" && echo "NC4 LICENSE missing                        -> FAIL at check 1" || { echo "NC4 expected 1 got $r"; cat "$tmp/o"; exit 1; }
  echo "all 5 controls behaved as specified (1 positive, 4 negative)"
  exit 0
fi

verify_one "${1:?usage: verify.sh <archive.tar.gz> | --self-test <good.tar.gz>}"
