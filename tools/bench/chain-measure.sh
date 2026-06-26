#!/usr/bin/env bash
# chain-measure.sh — measure the falcon three-binary chain for the MCU targets.
#
# Runs  falcon.wasm -> meld fuse -> loom optimize -> synth compile  for BOTH
# the F100 (cortex-m3, no FPU) and the M7 (cortex-m7dp) targets, and reports:
#   - wasm + code-section size at each chain stage (loom code-size is the
#     F100 flash/SRAM concern; custom/attestation sections are excluded),
#   - synth's skipped-function count broken down by ROOT CAUSE
#     (#369 float / register-exhaustion / AAPCS stack-arg #503),
#   - whether the M3 and M7dp ELFs are byte-identical (the #369 "no FPU" tell).
#
# This is the standing perf/optimization probe for the release-watch loop and the
# gale 1.7x->0.7 (synth#494) parity track. It does NOT gate; it characterizes.
# Findings: AFD-024 (#369), AFD-030 (synth#503), AFD-031 (loom#239).
#
# Usage:
#   tools/bench/chain-measure.sh <falcon.wasm>
# Tools are resolved (override via env):
#   MELD (../meld/target/release/meld), LOOM (../loom/target/release/loom),
#   SYNTH (../synth/target/release/synth), WASM_TOOLS (wasm-tools on PATH).
set -uo pipefail

SRC="${1:?usage: chain-measure.sh <falcon.wasm>}"
MELD="${MELD:-../meld/target/release/meld}"
LOOM="${LOOM:-../loom/target/release/loom}"
SYNTH="${SYNTH:-../synth/target/release/synth}"
WT="${WASM_TOOLS:-wasm-tools}"
OUT="$(mktemp -d)"

codesize() { "$WT" objdump "$1" 2>/dev/null | awk -F'|' '/^  code /{gsub(/[^0-9]/,"",$3); print $3}'; }

echo "## falcon three-binary chain — MCU measurement"
echo "input: $SRC ($(wc -c <"$SRC") bytes)"
echo "tools: meld=$("$MELD" --version 2>/dev/null | head -1 | tr -d '\n'); loom=$("$LOOM" --version 2>&1 | head -1 | tr -d '\n'); synth=$("$SYNTH" --version 2>/dev/null)"
echo

# stage 1+2: meld fuse, loom optimize
"$MELD" fuse "$SRC" -o "$OUT/fused.wasm"  >/dev/null 2>&1
"$LOOM" optimize "$OUT/fused.wasm" -o "$OUT/loom.wasm" >/dev/null 2>&1

echo "### chain sizes (code section, bytes)"
printf "  %-28s %s\n" "meld-fused"           "$(codesize "$OUT/fused.wasm")"
printf "  %-28s %s\n" "loom-optimized"       "$(codesize "$OUT/loom.wasm")"
echo

# stage 3: synth compile for both MCU targets (bash 3.2: no assoc arrays)
for tgt in cortex-m3 cortex-m7dp; do
  "$SYNTH" compile "$OUT/loom.wasm" -t "$tgt" --cortex-m -o "$OUT/$tgt.elf" >/dev/null 2>"$OUT/$tgt.err"
  echo "### synth -t $tgt"
  skip=$(grep -oE '[0-9]+ of [0-9]+ functions were skipped' "$OUT/$tgt.err" | tail -1)
  echo "  skipped: ${skip:-none}"
  echo "  by root cause:"
  f369=$(grep -c '#369' "$OUT/$tgt.err")
  freg=$(grep -cE 'register exhaustion|spill-slot|callee-saved|i64 register pair' "$OUT/$tgt.err")
  faap=$(grep -cE 'AAPCS stack-argument path|only i32 params' "$OUT/$tgt.err")
  printf "    %-22s %s\n" "#369 float"            "$f369"
  printf "    %-22s %s\n" "register-exhaustion"   "$freg"
  printf "    %-22s %s (synth#503)\n" "AAPCS stack-arg"      "$faap"
  command -v arm-none-eabi-size >/dev/null 2>&1 && arm-none-eabi-size "$OUT/$tgt.elf" 2>/dev/null | sed 's/^/  /'
  echo
done

# the #369 "FPU never used" tell: M3 == M7dp byte-for-byte
if [ -f "$OUT/cortex-m3.elf" ] && [ -f "$OUT/cortex-m7dp.elf" ]; then
  if cmp -s "$OUT/cortex-m3.elf" "$OUT/cortex-m7dp.elf"; then
    echo "NOTE: cortex-m3 and cortex-m7dp ELFs are BYTE-IDENTICAL — -t profile is"
    echo "      cosmetic for codegen (no soft-float path on M3, no hard-float on M7); see #369."
  else
    echo "NOTE: cortex-m3 and cortex-m7dp ELFs DIFFER — target-aware codegen is live."
  fi
fi
rm -rf "$OUT"
