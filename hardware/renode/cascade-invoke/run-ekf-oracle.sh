#!/usr/bin/env bash
# TEST-PIX-036 — the falcon ESTIMATOR (ekf#estimate) EXECUTES on emulated RT1176 Cortex-M7
# and tracks an independent wasmtime reference bit-exact over N ticks.
#
# WHY THIS RUNG EXISTS. jess's on-target differential has only ever invoked rate and mixer.
# ekf, attitude and position sit in the fused image and are NEVER CALLED — and relay's
# estimator fix, the change behind falcon v1.134 -> v1.139 that invalidated 18 of their
# closed-loop tests, lives in exactly that blind spot. AFD-122 recorded both that
# TEST-PIX-032's frozen baseline still holds bit-exact on v1.139 AND that this says nothing
# about the stages jess does not call. This closes the estimator half.
#
# WHAT IS OBSERVED, and why each part is not vacuous (all four established in wasmtime
# BEFORE the ARM code was written):
#   (1) BIT-EXACTNESS at tick 1 and tick N, all 14 state words each, against a reference
#       computed over the SAME module by a different execution path.
#   (2) THE FOLD over all 14 words of every tick. The estimator INTEGRATES (tick1 != tick2
#       != tick3), so the fold observes the state update, not just one call's arithmetic.
#       Five of the fourteen fields (pos-n/e/d, vel-d, innovation) are IDENTICALLY ZERO at
#       tick 1 and nonzero by tick 2 — a single-tick oracle would fold five constants.
#   (3) TRIP COUNT — the image writes the loop's OWN counter, incremented inside the loop,
#       not the requested N. Writing N up front proves only that the constant arrived.
#   (4) ENDPOINT MOTION — tick1 must differ from tickN; ekf_ref.py REFUSES to emit a
#       reference where they are equal, and that refusal is self-tested.
#
# THE THIRD CALLING SHAPE is the ABI content of this rung: ekf#estimate takes SIX FLATTENED
# f32 (6 <= the flattening limit of 16), where rate#tick takes a POINTER (18 > 16) and
# mixer#mix takes four flattened f32. build.sh asserts the six arguments really travel in
# VFP registers, and tools/abi/check-manifest.py checks all three shapes against meld's
# signature manifest rather than against a comment.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$D/../../.." && pwd)"
RENODE="${RENODE:-$HOME/renode-1.16.1/Contents/MacOS/renode}"
PY="${PY:-python3}"
SCRATCH="${SCRATCH:-$ROOT/.scratch}"
E="$SCRATCH/invoke/ekf.elf"
MOD="$SCRATCH/invoke/c.loom.wasm"
N="${N:-16}"                      # MUST match EKF_N in boot-ekf.S; asserted below.
RUNFOR="${RUNFOR:-4.0}"
WORDS=31                          # 1 trip count + 14 tick1 + 14 tickN + fold + sentinel

# WHERE THE WORDS COME FROM. By default this script runs each image on Renode. With
# WORDS_DIR=<dir> it runs nothing: it reads <dir>/{ekf,ekf_nc1,ekf_n<N-1>}.words, as written by
# tools/bench/on-target-run.sh READ=ekf on the real RT1176, and judges them with the SAME code
# below. Each capture names the sha256 of the ELF that produced it; a capture whose hash is not
# this tree's ELF is REFUSED, so words from another build cannot pass for this one. Its
# `origin` line is printed in the Result, so a Renode capture cannot be reported as silicon.
# DUMP_WORDS=<dir> (Renode mode only) writes the Renode words in the same format; CI uses it to
# build the planted bad captures in tools/ci/test-ekf-words-dir.sh.
# ELF_DIR=<dir> (WORDS_DIR mode only) judges captures against the ELFs that actually ran on the
# target, kept beside the captures as evidence, instead of this tree's build: the bench host's
# compiler is not CI's, so a CI-built image never has the silicon image's sha256. The captures'
# sha256 lines still have to name these ELFs, and the reference still comes from this tree's
# module, so a stale or foreign evidence directory fails rather than passes.
WORDS_DIR="${WORDS_DIR:-}"
DUMP_WORDS="${DUMP_WORDS:-}"
ELF_DIR="${ELF_DIR:-}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
RESCDIR="$(mktemp -d)"
RESC="$RESCDIR/oracle.resc"
trap 'rm -rf "$RESCDIR"' EXIT
sha() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | awk '{print $1}'; }
if [ -n "$WORDS_DIR" ]; then
  [ -n "$DUMP_WORDS" ] && fail "WORDS_DIR and DUMP_WORDS together would copy a capture into itself"
  [ -d "$WORDS_DIR" ] || fail "WORDS_DIR=$WORDS_DIR is not a directory"
  WHERE="the target named by the captures' origin lines"
  if [ -n "$ELF_DIR" ]; then
    [ -d "$ELF_DIR" ] || fail "ELF_DIR=$ELF_DIR is not a directory"
    E="$ELF_DIR/ekf.elf"
  fi
else
  [ -n "$ELF_DIR" ] && fail "ELF_DIR is only meaningful with WORDS_DIR"
  [ -x "$RENODE" ] || { echo "SKIP: renode not at $RENODE" >&2; exit 2; }
  WHERE="emulated RT1176 Cortex-M7 (Renode)"
fi
[ -f "$E" ]   || fail "ekf image missing — run build.sh first"
[ -f "$MOD" ] || fail "module missing — run build.sh first"

# The tick count lives in TWO places (the image and the reference). Derive the image's value
# from its source and refuse to run if they disagree, rather than silently comparing an
# N-tick run against an M-tick reference.
# PREFER THE RECORDED VALUE. build.sh writes the EFFECTIVE tick count to ekf.n beside the
# image, because EKF_N is now overridable and grepping boot-ekf.S would read the DEFAULT
# whatever was built — comparing an N-tick run against an M-tick reference while looking
# correct. The source grep remains as the fallback for an image built before ekf.n existed.
if [ -f "$SCRATCH/invoke/ekf.n" ]; then
  SRC_N="$(tr -dc '0-9' < "$SCRATCH/invoke/ekf.n")"
else
  SRC_N="$(grep -oE '^[[:space:]]*\.equ[[:space:]]+EKF_N,[[:space:]]*[0-9]+' "$D/boot-ekf.S" | grep -oE '[0-9]+$')"
fi
[ -n "$SRC_N" ] || fail "could not determine the image's EKF_N (no $SCRATCH/invoke/ekf.n and no readable .equ in boot-ekf.S)"
[ "$SRC_N" = "$N" ] || fail "EKF_N in boot-ekf.S is $SRC_N but the oracle is checking N=$N"

# FRESHNESS. This oracle reads a prebuilt ELF, so a FAILED build leaves the previous run's
# image in place and the oracle passes on it — the AFD-047 staleness class, which has now bitten
# this repo three times (AFD-049, and AFD-124's consumers left on a renamed pin path).
if [ -n "$ELF_DIR" ]; then
  echo "   freshness not applicable: the ELFs are evidence from $ELF_DIR, bound to the captures by sha256"
else
for src in "$D/harness.c" "$D/boot-ekf.S" "$D/vectors.inc" "$D/link.ld" "$MOD"; do
  [ -f "$src" ] || fail "missing build input $src"
  # Strictly newer only: `-nt` is false for equal mtimes, and one build.sh run writes the
  # module and the ELF inside the same second.
  [ "$src" -nt "$E" ] && fail "$(basename "$src") is NEWER than ekf.elf — STALE image; re-run build.sh (a failed build leaves the previous image in place)"
done
echo "   ekf.elf is newer than harness.c, boot-ekf.S, vectors.inc, link.ld and the module"
fi

read_ekf() {   # $1 = elf ; echoes $WORDS hex words
  if [ -n "$WORDS_DIR" ]; then read_capture "$1"; return; fi
  local w; w="$(read_renode "$1")"
  # The last two words are the exception log (vectors.inc). An exception now RETURNS instead of
  # crashing the run, so a run can complete having taken one; Renode raises none in these images.
  # Require the magic and a count of 0, then pass on only the $WORDS result words. On a refusal
  # nothing is echoed, so the caller fails its word count with this reason on stderr.
  local a; a=( $w )
  if [ "${#a[@]}" -ne $((WORDS + 2)) ] || [ "$(norm "${a[WORDS]}")" != 0x1E55E7C0 ] || [ "$(norm "${a[WORDS+1]}")" != 0x00000000 ]; then
    echo "FAIL: $(basename "$1"): exception log is [${a[WORDS]:-absent} ${a[WORDS+1]:-absent}], need magic 0x1E55E7C0 and 0 exceptions taken" >&2
    return 0
  fi
  w="${a[*]:0:WORDS}"
  echo "   $(basename "$1"): exception log magic present, 0 exceptions taken" >&2
  if [ -n "$DUMP_WORDS" ]; then
    mkdir -p "$DUMP_WORDS"
    { echo "sha256 $(sha "$1")"
      echo "origin renode $("$RENODE" --version 2>/dev/null | head -1 | awk '{print $2}') pixhawk6xrt.repl"
      echo "$w"; } > "$DUMP_WORDS/$(basename "$1" .elf).words"
  fi
  echo "$w"
}

# A capture is three lines: `sha256 <hex>`, `origin <text>`, then the words. Anything else is
# refused rather than guessed at. Called in a command substitution, so `fail` here only ends the
# subshell; it prints nothing on stdout, and the word-count check at each call site then stops
# the run.
read_capture() {
  local f="$WORDS_DIR/$(basename "$1" .elf).words"
  [ -f "$f" ] || fail "no capture $f — 'could not run' on the target, not a result"
  local want got origin
  want="$(sha "$1")"
  got="$(sed -n '1s/^sha256 //p' "$f")"
  [ "$got" = "$want" ] || fail "$f was captured from an ELF with sha256 '$got', but this tree's
   $(basename "$1") is $want — those words are not this image's"
  origin="$(sed -n '2s/^origin //p' "$f")"
  [ -n "$origin" ] || fail "$f has no origin line — where these words executed is unknown"
  echo "   $(basename "$f"): origin $origin" >&2
  # openocd prints bare hex; Renode prints 0x-prefixed. Accept either, emit 0x-prefixed.
  sed -n '3p' "$f" | tr ' ' '\n' | grep -E '^(0x)?[0-9a-fA-F]{1,8}$' | sed -E 's/^(0x)?/0x/' | tr '\n' ' '
}

read_renode() {   # $1 = elf ; echoes $WORDS hex words
  {
    echo "using sysbus"
    echo 'mach create "tp36"'
    echo "machine LoadPlatformDescription @hardware/renode/pixhawk6xrt.repl"
    echo "sysbus LoadELF @$1"
    echo "emulation RunFor \"$RUNFOR\""
    echo "pause"
    echo 'echo "B"'
    for i in $(seq 0 $((WORDS - 1))); do
      printf 'sysbus ReadDoubleWord 0x%08X\n' $((0x20011400 + 4 * i))
    done
    echo "sysbus ReadDoubleWord 0x20011F00"   # the exception log (vectors.inc): magic, count
    echo "sysbus ReadDoubleWord 0x20011F04"
    echo 'echo "E"'
  } > "$RESC"
  ( cd "$ROOT" && "$RENODE" --console --disable-xwt -e "include @$RESC
quit" 2>&1 ) | perl -pe 's/\e\[[0-9;]*m//g' | "$PY" -c '
import sys,re
g=False;out=[]
for l in sys.stdin:
    l=l.rstrip()
    if l.strip()=="B": g=True; continue
    if l.strip()=="E": break
    if g:
        m=re.fullmatch(r"\s*(0x[0-9a-fA-F]+)\s*",l)
        if m: out.append(m.group(1))
print(" ".join(out))'
}

norm() { printf '0x%08X' "$1"; }

echo "== 1. $N estimator ticks on $WHERE =="
W=( $(read_ekf "$E") )
[ "${#W[@]}" -eq "$WORDS" ] || fail "expected $WORDS words from the ekf region, got ${#W[@]} (${W[*]:-none})"

sent="$(norm "${W[30]}")"
[ "$sent" = "0x1E55E4F0" ] || fail "completion sentinel is $sent, not 0x1E55E4F0 — the run did not finish all $N ticks (raise RUNFOR)"
ran="$(norm "${W[0]}")"
[ "$ran" = "$(norm "$N")" ] || fail "the loop ran $ran iterations, expected $(norm "$N")"
echo "   sentinel 0x1E55E4F0 present; loop reports $N iterations actually run"

echo "== 2. independent wasmtime reference over the SAME module and N =="
# Distinguish a CRASHED generator from a considered refusal (AFD-121): reporting any nonzero
# exit as the vacuity refusal once came within one step of a false claim about relay's estimator.
ref_rc=0
REF="$("$PY" "$ROOT/tools/cascade-differential/ekf_ref.py" "$MOD" "$N" --format json 2>"$SCRATCH/invoke/ekf_ref.err")" \
  || ref_rc=$?
if [ "$ref_rc" -ne 0 ]; then
  sed 's/^/   /' "$SCRATCH/invoke/ekf_ref.err" >&2
  if grep -qi 'REFUSING' "$SCRATCH/invoke/ekf_ref.err"; then
    fail "the reference generator REFUSED to emit a vacuous reference — see its reason above.
   That is a verdict about the estimator's dynamics, not a crash."
  fi
  fail "the reference generator CRASHED (exit $ref_rc) — this is 'could not run', NOT a verdict
   about the estimator. See the error above."
fi

r_t1="$("$PY" -c "import json,sys;print(' '.join('0x%08X'%w for w in json.loads(sys.argv[1])['tick1']))" "$REF")"
r_tN="$("$PY" -c "import json,sys;print(' '.join('0x%08X'%w for w in json.loads(sys.argv[1])['tickN']))" "$REF")"
r_f="$("$PY"  -c "import json,sys;print('0x%08X'%json.loads(sys.argv[1])['fold'])" "$REF")"

g_t1=""; for i in $(seq 1 14);  do g_t1="$g_t1$(norm "${W[$i]}") "; done; g_t1="${g_t1% }"
g_tN=""; for i in $(seq 15 28); do g_tN="$g_tN$(norm "${W[$i]}") "; done; g_tN="${g_tN% }"
g_f="$(norm "${W[29]}")"

FIELDS=(qw qx qy qz pos-n pos-e pos-d vel-n vel-e vel-d wx wy wz innovation)
show() {  # $1 label  $2 target words  $3 reference words
  local -a t r; t=( $2 ); r=( $3 ); local i
  for i in $(seq 0 13); do
    if [ "${t[$i]}" = "${r[$i]}" ]; then
      printf '      %-11s %s  matches\n' "${FIELDS[$i]}" "${t[$i]}"
    else
      printf '      %-11s target %s  reference %s  DIFFERS\n' "${FIELDS[$i]}" "${t[$i]}" "${r[$i]}"
    fi
  done
}
echo "   tick 1"
show "tick1" "$g_t1" "$r_t1"
[ "$g_t1" = "$r_t1" ] || fail "tick 1 state does NOT match the wasmtime reference"
echo "   tick $N"
show "tickN" "$g_tN" "$r_tN"
[ "$g_tN" = "$r_tN" ] || fail "tick $N state does NOT match the wasmtime reference"
[ "$g_f" = "$r_f" ] || fail "fold over $N ticks: target $g_f reference $r_f"
echo "   fold    $g_f  matches over all $((14 * N)) state words"

echo "== 3. controls =="
[ "$g_t1" != "$g_tN" ] \
  || fail "tick1 == tickN on target — the estimator did not integrate, so this oracle observed
   nothing. A build that dropped the state update produces exactly this."
echo "   tick1 != tickN (the estimator integrates; the run is not a constant)"

"$PY" "$ROOT/tools/cascade-differential/ekf_ref.py" --self-test >/dev/null 2>&1 \
  || fail "ekf_ref.py's own vacuity guards do not pass their self-test — its refusals cannot be trusted"
echo "   ekf_ref.py vacuity guard self-test PASS"

# CONTROL A (ATTRIBUTIVE) — one imu scalar perturbed, embedder init fully intact. All SIX imu
# scalars were measured LIVE in wasmtime (each moves 5-8 of the 14 state fields), so a moved
# fold attributes the result to the computation rather than merely to liveness. Contrast the
# composed-app oracle, whose own scope line reports only 4 of its 18 inputs move its fold.
NC1="${ELF_DIR:-$SCRATCH/invoke}/ekf_nc1.elf"
[ -f "$NC1" ] || fail "ekf_nc1.elf missing — build.sh must build the controls"
W1=( $(read_ekf "$NC1") )
[ "${#W1[@]}" -eq "$WORDS" ] || fail "control A returned ${#W1[@]} words, not $WORDS"
[ "$(norm "${W1[30]}")" = "0x1E55E4F0" ] || fail "control A did not COMPLETE — a crash is not a control"
nc1_f="$(norm "${W1[29]}")"
[ "$nc1_f" != "$g_f" ] \
  || fail "control A folded IDENTICALLY ($nc1_f) with gy perturbed — the oracle cannot see its
   own input, so bit-exactness above attributes nothing."
echo "   perturbed-gy control completed, folded $nc1_f != $g_f  (a wrong-but-plausible result IS caught)"

# CONTROL B (ATTRIBUTIVE, ITERATION COUNT) — the baseline with one tick fewer (EKF_N=N-1, one
# loaded byte different at N=16). It is judged IN FULL against wasmtime at N-1: trip word, tick-1
# state (unchanged), tick-(N-1) state and fold. So it must complete and be RIGHT, which a control
# that merely "folds differently" never had to be. It replaced the init-skipped image (ekf_nc2),
# which attributed nothing and does not complete on silicon (AFD-153).
NB=$((N - 1))
NBE="${ELF_DIR:-$SCRATCH/invoke}/ekf_n$NB.elf"
[ -f "$NBE" ] || fail "ekf_n$NB.elf missing — build.sh must build the controls"
W2=( $(read_ekf "$NBE") )
# AN EMPTY READ IS NOT A DIFFERENT FOLD. An unreadable control B once left its fold empty,
# "" != the baseline fold, and the run printed Result: PASS with control B never observed.
[ "${#W2[@]}" -eq "$WORDS" ] || fail "control B returned ${#W2[@]} words, not $WORDS — control B was NOT observed"
[ "$(norm "${W2[30]}")" = "0x1E55E4F0" ] || fail "control B did not COMPLETE — a crash is not a control"
[ "$(norm "${W2[0]}")" = "$(norm "$NB")" ] || fail "control B ran $(norm "${W2[0]}") iterations, expected $(norm "$NB")"
ref_rc=0
REFB="$("$PY" "$ROOT/tools/cascade-differential/ekf_ref.py" "$MOD" "$NB" --format json 2>"$SCRATCH/invoke/ekf_ref_b.err")" \
  || ref_rc=$?
[ "$ref_rc" -eq 0 ] || { sed 's/^/   /' "$SCRATCH/invoke/ekf_ref_b.err" >&2; fail "the reference generator failed at N=$NB (exit $ref_rc) — control B could not be judged"; }
rb_tN="$("$PY" -c "import json,sys;print(' '.join('0x%08X'%w for w in json.loads(sys.argv[1])['tickN']))" "$REFB")"
rb_f="$("$PY"  -c "import json,sys;print('0x%08X'%json.loads(sys.argv[1])['fold'])" "$REFB")"
b_t1=""; for i in $(seq 1 14);  do b_t1="$b_t1$(norm "${W2[$i]}") "; done; b_t1="${b_t1% }"
b_tN=""; for i in $(seq 15 28); do b_tN="$b_tN$(norm "${W2[$i]}") "; done; b_tN="${b_tN% }"
nb_f="$(norm "${W2[29]}")"
[ "$b_t1" = "$r_t1" ] || fail "control B tick 1 state does NOT match the wasmtime reference"
[ "$b_tN" = "$rb_tN" ] || { show "tickN" "$b_tN" "$rb_tN"; fail "control B tick $NB state does NOT match the wasmtime reference at N=$NB"; }
[ "$nb_f" = "$rb_f" ] || fail "control B fold over $NB ticks: target $nb_f reference $rb_f"
[ "$nb_f" != "$g_f" ] || fail "control B folded IDENTICALLY to the baseline with one tick fewer — the fold does not see the iteration count"
echo "   one-tick-fewer control: $NB iterations, tick $NB state and fold $nb_f match wasmtime at N=$NB, != $g_f"

echo
[ -n "$WORDS_DIR" ] && WHERE="$(sed -n '2s/^origin //p' "$WORDS_DIR/ekf.words")"
echo "Result: PASS — falcon's ESTIMATOR ran $N ticks on $WHERE and tracked"
echo "        the wasmtime reference bit-exact on all 14 state words at tick 1 and tick $N,"
echo "        and across a fold of all $((14 * N)) state words. The estimator integrates"
echo "        (tick1 != tickN), perturbing ONE of its six live inputs moves the fold, and one"
echo "        tick fewer (control B) matches wasmtime at N=$NB in full."
echo "        This is the FIRST jess measurement of any cascade stage other than rate/mixer."
