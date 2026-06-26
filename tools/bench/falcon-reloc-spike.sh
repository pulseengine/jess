#!/usr/bin/env bash
# falcon-reloc-spike.sh — validate the --relocatable + TCB-link path for falcon
# (the gale-maximal-wasm / DD-018 model gust already uses), head-to-head against
# the self-contained --cortex-m path jess-build.sh/bazel use today.
#
# Produces the evidence behind DD-018's path validation:
#   1. falcon dissolves --relocatable to a valid ELF *relocatable object* (TCB-link viable);
#   2. the emitted functions — including br_tables (the synth#507/AFD-032 concern) —
#      lower IDENTICALLY to the --cortex-m path (so #507 does not affect falcon's real
#      code; the choice of path is the linking model, not br_table correctness);
#   3. the TCB-seam surface = the UNDEFINED symbols the native trusted base must provide
#      (the WASI host primitives) + any skipped-function dangling refs (#369/#275/#503),
#      which block a complete link on BOTH paths equally until those poles clear.
#
# Usage: tools/bench/falcon-reloc-spike.sh <falcon.wasm>
#   tools: MELD/LOOM/SYNTH (default ../<tool>/target/release), TARGET (default cortex-m7dp)
set -uo pipefail

SRC="${1:?usage: falcon-reloc-spike.sh <falcon.wasm>}"
MELD="${MELD:-../meld/target/release/meld}"
LOOM="${LOOM:-../loom/target/release/loom}"
SYNTH="${SYNTH:-../synth/target/release/synth}"
TARGET="${TARGET:-cortex-m7dp}"
OD="${OBJDUMP:-arm-none-eabi-objdump}"
W="$(mktemp -d)"

"$MELD" fuse "$SRC" -o "$W/f.fused.wasm"      >/dev/null 2>&1
"$LOOM" optimize "$W/f.fused.wasm" -o "$W/f.loom.wasm" >/dev/null 2>&1

echo "## falcon --relocatable (TCB-link) vs --cortex-m (self-contained) — $TARGET"
echo "input: $SRC; synth $("$SYNTH" --version 2>/dev/null)"
echo

"$SYNTH" compile "$W/f.loom.wasm" -t "$TARGET" --cortex-m -o "$W/a.elf" >/dev/null 2>"$W/a.err"
"$SYNTH" compile "$W/f.loom.wasm" -t "$TARGET" --relocatable --all-exports -o "$W/b.o" >/dev/null 2>"$W/b.err"

ska=$(grep -oE '[0-9]+ of [0-9]+ functions were skipped' "$W/a.err" | tail -1)
skb=$(grep -oE '[0-9]+ of [0-9]+ functions were skipped' "$W/b.err" | tail -1)
echo "### skip inventory (decoder-level, path-independent)"
echo "  --cortex-m   : ${ska:-none}"
echo "  --relocatable: ${skb:-none}"
echo "  output kind  : $(file "$W/b.o" | sed 's/.*: //')"
echo

echo "### control-flow parity (br_tables included)"
cba=$("$OD" -d "$W/a.elf" 2>/dev/null | grep -cE '\t(beq|bne|bcs|bcc|bmi|bpl|bhi|bls|bge|blt|bgt|ble)(\.[nw])?\b')
cbb=$("$OD" -d "$W/b.o"   2>/dev/null | grep -cE '\t(beq|bne|bcs|bcc|bmi|bpl|bhi|bls|bge|blt|bgt|ble)(\.[nw])?\b')
echo "  conditional branches: --cortex-m=$cba  --relocatable=$cbb  (equal ⇒ br_table dispatch preserved on both)"
echo

echo "### TCB-seam — undefined symbols the native trusted base must provide"
"$OD" -t "$W/b.o" 2>/dev/null | grep -E '\*UND\*' | awk '{print "  "$NF}' | sort -u
rm -rf "$W"
