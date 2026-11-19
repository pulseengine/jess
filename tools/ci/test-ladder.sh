#!/usr/bin/env bash
# Self-test for tools/ladder (jess-ladder): every planted input gives its stated result.
#
#   tools/ci/test-ladder.sh <ladder-bin> <renode-words-dir> <invoke-dir> <evidence-dir>
#
# <renode-words-dir> holds Renode captures of THIS tree's images (run-ekf-oracle.sh DUMP_WORDS=),
# <invoke-dir> the ELFs they came from, <evidence-dir> the committed silicon evidence. The Renode
# captures are the raw material for the planted sets: relabelled as silicon they are the only
# input this repo has that passes, so they are what proves the generator can write a pass at all.
# Prints "N of M cases behaved as expected" and Result: PASS|FAIL; exits 1 on any mismatch.
set -uo pipefail
L="$1"; RW="$2"; INV="$3"; EV="$4"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
J="$ROOT/hardware/renode/cascade-invoke/run-ekf-oracle.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ok=0; n=0

# kit <name>: a pass-path evidence dir from the Renode captures and this tree's ELFs,
# with every origin relabelled as silicon.
kit() {
  local d="$T/$1"; mkdir -p "$d"
  for i in ekf ekf_nc1 ekf_nc2; do
    cp "$INV/$i.elf" "$d/"
    sed '2s/^origin .*/origin rt1176-silicon planted-from-renode/' "$RW/$i.words" > "$d/$i.words"
  done
  echo "$d"
}

# expect <case> <want: pass|fail|notrun|refused> <r0-dir-or-empty>
expect() {
  local name="$1" want="$2" dir="$3" out="$T/$1.json" got
  n=$((n+1))
  "$L" generate --version v0.0.0-selftest --target pixhawk-6xrt --judge "$J" ${dir:+--r0 "$dir"} --out "$out" >"$T/$1.log" 2>&1
  case $? in
    2) got=refused ;;
    0) got="$(jq -r '.facts[] | select(.id=="pixhawk-6xrt/r0") | "ran:\(.ran),pass:\(.pass)"' "$out")"
       case "$got" in
         ran:true,pass:true) got=pass ;;
         ran:true,pass:false) got=fail ;;
         ran:false,pass:false) got=notrun ;;
       esac
       "$L" check "$out" --target pixhawk-6xrt >/dev/null || got="$got+INVALID" ;;
    *) got="exit $?" ;;
  esac
  if [ "$got" = "$want" ]; then ok=$((ok+1)); echo "  ok   $name -> $got"
  else echo "  BAD  $name -> $got, expected $want"; sed 's/^/       /' "$T/$1.log" | tail -5; fi
}

expect pass-path        pass    "$(kit pass)"
expect genuine-silicon  fail    "$EV"
# ...and it fails for the reason the evidence predicts: control B (nc2) never produced words on
# silicon. Failing anywhere earlier would mean this tree no longer reproduces the silicon words.
n=$((n+1)); why="$(jq -r '.facts[] | select(.id=="pixhawk-6xrt/r0") | .detail.reason' "$T/genuine-silicon.json" 2>/dev/null)"
case "$why" in *ekf_nc2.words*) ok=$((ok+1)); echo "  ok   genuine-silicon fails at control B: $why" ;;
  *) echo "  BAD  genuine-silicon fails for another reason: $why" ;; esac
d="$(kit tampered)"
read -r -a w < <(sed -n 3p "$d/ekf.words"); w[20]="$(printf '0x%08x' $(( 16#${w[20]#0x} ^ 1 )))"
{ sed -n 1,2p "$d/ekf.words"; echo "${w[*]}"; } > "$d/x" && mv "$d/x" "$d/ekf.words"
expect tampered-word    fail    "$d"
d="$(kit emulator)"; cp "$RW/ekf.words" "$d/ekf.words"
expect emulator-origin  refused "$d"
d="$(kit shamismatch)"; cp "$INV/ekf_nc1.elf" "$d/ekf.elf"
expect sha-mismatch     refused "$d"
d="$(kit noelf)"; rm "$d/ekf_nc1.elf"
expect missing-elf      refused "$d"
d="$(kit nobaseline)"; rm "$d/ekf.words"
expect no-baseline      notrun  "$d"
expect no-evidence-dir  notrun  "$T/does-not-exist"
expect no-r0-given      notrun  ""

# The checker itself: an omitted rung and a field outside the schema must both be INVALID.
for c in drop-rung extra-field pass-without-run; do
  n=$((n+1)); f="$T/$c.json"
  case $c in
    drop-rung)        jq 'del(.facts[] | select(.id=="pixhawk-6xrt/flight"))' "$T/no-r0-given.json" > "$f" ;;
    extra-field)      jq '. + {verdict: "pass"}' "$T/no-r0-given.json" > "$f" ;;
    pass-without-run) jq '(.facts[] | select(.id=="pixhawk-6xrt/hil") | .pass) = true' "$T/no-r0-given.json" > "$f" ;;
  esac
  if "$L" check "$f" --target pixhawk-6xrt >"$T/$c.log" 2>&1; then echo "  BAD  check accepted $c"
  else [ $? -eq 1 ] && { ok=$((ok+1)); echo "  ok   check refuses $c"; } || echo "  BAD  check $c exited oddly"; fi
done

echo "$ok of $n cases behaved as expected (1 pass path, 2 genuine, 7 planted generator inputs, 3 planted checker inputs)"
if [ "$ok" -eq "$n" ]; then echo "Result: PASS"; else echo "Result: FAIL"; exit 1; fi
