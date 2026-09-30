#!/usr/bin/env bash
# SECOND-EMULATOR CROSS-CHECK for AFD-125 — is the estimator divergence synth's or Renode's?
#
# THE QUESTION THIS ANSWERS. run-ekf-oracle.sh shows the synth-lowered estimator disagreeing with
# wasmtime over the same fused module, on four of fourteen state words. Two candidate causes
# survived every other control: a synth LOWERING defect, or a Renode fpv5-d16 MODELLING defect.
# jess cannot tell them apart from one emulator, and the bench has been empty since 2026-09-25.
#
# It can be told apart WITHOUT silicon, by running the SAME ELF on a completely different
# emulator. QEMU's mps2-an500 is a Cortex-M7 machine with a different memory map, different
# peripherals and an independently written FPU implementation. If the two agree bit-for-bit, the
# emulator is not the variable.
#
# MEASURED, 2026-09-30: all 31 parked words are BIT-IDENTICAL between
#     Renode 1.16.1, hardware/renode/pixhawk6xrt.repl (i.MX RT1176 model)
#     QEMU   11.1.1, -machine mps2-an500 -cpu cortex-m7
# including the four diverging state words, the FNV-1a fold over 16 ticks (0x684578d1) and the
# completion sentinel. So Renode is EXONERATED and the divergence is in the lowering.
#
# A USEFUL SIDE RESULT: the image boots and runs to completion on a machine model jess never
# targeted, which independently exercises the embedder-register contract (R9 globals, R10 linmem
# size, R11 linmem base — synth#1131) on a second implementation.
#
# WHY THE ELF LOADS UNCHANGED: link.ld puts .vectors/.text/.rodata at 0x00000000 and reserves
# RAM at 0x20000000. Both regions are RAM on mps2-an500, so no relinking is needed. Nothing here
# is tuned to the machine; if that ever stops being true this script must FAIL, not adapt.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$D/../.." && pwd)"
QEMU="${QEMU:-qemu-system-arm}"
SCRATCH="${SCRATCH:-$ROOT/.scratch}"
E="${E:-$SCRATCH/invoke/ekf.elf}"
BASE=0x20011400
WORDS=31
SETTLE="${SETTLE:-10}"        # wall seconds before halting; the image spins after it finishes

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v "$QEMU" >/dev/null 2>&1 || { echo "SKIP: $QEMU not on PATH" >&2; exit 2; }
[ -f "$E" ] || fail "ekf image missing at $E — run hardware/renode/cascade-invoke/build.sh first"
"$QEMU" -machine help 2>/dev/null | grep -q '^mps2-an500' \
  || fail "this $QEMU has no mps2-an500 machine — cannot run a Cortex-M7 cross-check"

read_qemu() {   # echoes $WORDS lowercase hex words
  { sleep "$SETTLE"; echo "stop"; printf 'xp /%dxw %s\n' "$WORDS" "$BASE"; sleep 2; echo "quit"; } \
    | "$QEMU" -machine mps2-an500 -cpu cortex-m7 -display none -serial none \
        -monitor stdio -kernel "$1" 2>&1 \
    | grep -oE '^200114[0-9a-f]{2}: (0x[0-9a-f]{8} ?)+' \
    | grep -oE '0x[0-9a-f]{8}' | sed 's/^0x//' | tr '\n' ' '
}

echo "== run the estimator image on QEMU mps2-an500 (Cortex-M7) =="
Q=( $(read_qemu "$E") )
[ "${#Q[@]}" -eq "$WORDS" ] \
  || fail "expected $WORDS words from QEMU, got ${#Q[@]} (${Q[*]:-none}).
   'could not run' is not a verdict about the lowering — check the monitor output by hand."
[ "${Q[30]}" = "1e55e4f0" ] \
  || fail "completion sentinel is ${Q[30]}, not 1e55e4f0 — the image did not finish under QEMU
   (raise SETTLE). A truncated run must not be compared."
trip=$((16#${Q[0]}))
echo "   sentinel 1e55e4f0 present; loop reports $trip iterations"
echo "   fold ${Q[29]}"

# If a Renode capture is supplied, compare word for word. Passed in rather than re-run here so
# this script stays runnable by someone who has QEMU and no Renode — which is the whole point of
# a second-emulator check.
if [ -n "${RENODE_WORDS:-}" ] && [ -f "$RENODE_WORDS" ]; then
  echo "== compare against the Renode capture in $RENODE_WORDS =="
  R=( $(tr 'A-F' 'a-f' < "$RENODE_WORDS" | tr -d '\r') )
  [ "${#R[@]}" -eq "$WORDS" ] || fail "the Renode capture has ${#R[@]} words, not $WORDS"
  diffs=0
  for i in $(seq 0 $((WORDS - 1))); do
    if [ "${R[$i]}" != "${Q[$i]}" ]; then
      printf '   word %2d  renode %s  qemu %s  DIFFERS\n' "$i" "${R[$i]}" "${Q[$i]}"
      diffs=$((diffs + 1))
    fi
  done
  if [ "$diffs" -eq 0 ]; then
    echo "   all $WORDS words BIT-IDENTICAL across the two emulators"
    echo
    echo "Result: the EMULATOR IS NOT THE VARIABLE. Two independently written Cortex-M7"
    echo "        implementations produce the same bits from the same synth-lowered object, and"
    echo "        both disagree with wasmtime over the same wasm module (AFD-125). That points at"
    echo "        the LOWERING. It does not, on its own, say which instruction or which pass."
  else
    echo
    echo "Result: the two emulators DISAGREE on $diffs word(s). That is a different finding from"
    echo "        AFD-125 and a more alarming one — the same object producing different bits on"
    echo "        two Cortex-M7 models means at least one of them is wrong. Do not fold this into"
    echo "        the lowering question; investigate it separately."
    exit 1
  fi
else
  echo "   (set RENODE_WORDS=<file of $WORDS hex words> to compare against a Renode capture)"
fi
