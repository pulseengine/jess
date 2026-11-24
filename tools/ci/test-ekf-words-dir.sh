#!/usr/bin/env bash
# Acceptance test for run-ekf-oracle.sh WORDS_DIR mode: the mode that judges words captured on
# the real RT1176 (tools/bench/on-target-run.sh READ=ekf). CI has no board, so this proves the
# JUDGE, not the board: a genuine capture set must PASS and each planted bad set must FAIL for
# its own stated reason. A FAIL for any other reason counts as a test failure, because a judge
# that refuses everything would otherwise look potent.
#
# Usage: test-ekf-words-dir.sh <dir of genuine captures from DUMP_WORDS>
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$D/../.." && pwd)"
ORACLE="$ROOT/hardware/renode/cascade-invoke/run-ekf-oracle.sh"
G="${1:?usage: test-ekf-words-dir.sh <genuine capture dir>}"
for f in ekf ekf_nc1 ekf_n15; do
  [ -f "$G/$f.words" ] || { echo "FAIL: genuine capture $G/$f.words missing — could not run"; exit 1; }
done
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; total=0

# case <name> <expect: pass|fail> <text the output must contain> ; mutate "$T/$name" before
run_case() {
  local name="$1" want="$2" text="$3" out rc=0
  total=$((total + 1))
  out="$(WORDS_DIR="$T/$name" "$ORACLE" 2>&1)" || rc=$?
  if [ "$want" = pass ] && [ "$rc" -eq 0 ] && grep -qF -- "$text" <<<"$out"; then
    echo "   ok    $name: PASS as expected"; pass=$((pass + 1))
  elif [ "$want" = fail ] && [ "$rc" -ne 0 ] && grep -qF -- "$text" <<<"$out"; then
    echo "   ok    $name: refused, for the stated reason"; pass=$((pass + 1))
  else
    echo "   WRONG $name: wanted $want with '$text', got exit $rc:"; sed 's/^/         /' <<<"$out" | tail -8
  fi
}
fresh() { rm -rf "${T:?}/$1"; cp -R "$G" "$T/$1"; }
word() {  # word <file> <index> <new value> : replace one word on the words line
  awk -v i="$2" -v v="$3" 'NR==3{split($0,w," "); w[i+1]=v; s=w[1]; for(k=2;k<=length(w);k++) s=s" "w[k]; print s; next} {print}' \
    "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

fresh genuine
run_case genuine pass "Result: PASS"

# the capture came from a different build of the image
fresh wrong-sha;    sed -i.bak '1s/^sha256 .*/sha256 0000000000000000000000000000000000000000000000000000000000000000/' "$T/wrong-sha/ekf.words"
run_case wrong-sha fail "those words are not this image's"

# one tick-16 state word off by one ulp
fresh flipped
v="$(sed -n 3p "$T/flipped/ekf.words" | awk '{print $21}')"
word "$T/flipped/ekf.words" 20 "$(printf '0x%08X' $(( v ^ 1 )))"
run_case flipped fail "tick 16 state does NOT match the wasmtime reference"

# the image did not finish: sentinel absent
fresh no-sentinel;  word "$T/no-sentinel/ekf.words" 30 0x00000000
run_case no-sentinel fail "completion sentinel is 0x00000000"

# a control was never run on the target
fresh no-control;   rm "$T/no-control/ekf_nc1.words"
run_case no-control fail "'could not run' on the target"

# control B was never observed: it must not pass as "a different fold"
fresh no-control-b; rm "$T/no-control-b/ekf_n15.words"
run_case no-control-b fail "control B was NOT observed"

# control B reports the baseline's 16-tick words: it completed, but did not run one tick fewer
fresh blind-control-b
{ sed -n 1p "$T/blind-control-b/ekf_n15.words"; sed -n 2,3p "$T/blind-control-b/ekf.words"; } > "$T/blind-control-b/x" \
  && mv "$T/blind-control-b/x" "$T/blind-control-b/ekf_n15.words"
run_case blind-control-b fail "control B ran 0x00000010 iterations, expected 0x0000000F"

# control B ran 15 ticks but one tick-15 state word is off by one ulp
fresh flipped-b
v="$(sed -n 3p "$T/flipped-b/ekf_n15.words" | awk '{print $21}')"
word "$T/flipped-b/ekf_n15.words" 20 "$(printf '0x%08X' $(( v ^ 1 )))"
run_case flipped-b fail "control B tick 15 state does NOT match the wasmtime reference"

# where the words executed is not stated
fresh no-origin;    sed -i.bak '2d' "$T/no-origin/ekf.words"
run_case no-origin fail "has no origin line"

# the perturbed-input control reports the baseline's words: the control would attribute nothing
fresh blind-control
{ sed -n 1p "$T/blind-control/ekf_nc1.words"; sed -n 2,3p "$T/blind-control/ekf.words"; } > "$T/blind-control/x" \
  && mv "$T/blind-control/x" "$T/blind-control/ekf_nc1.words"
run_case blind-control fail "control A folded IDENTICALLY"

echo "$pass of $total cases behaved as expected (1 genuine, $((total - 1)) planted)"
[ "$pass" -eq "$total" ] && echo "Result: PASS" || { echo "Result: FAIL"; exit 1; }
