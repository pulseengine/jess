#!/usr/bin/env bash
# Assert the pinned synth does NOT exhibit synth#1189 (the if/else join aliasing a local's
# home register on the ARM direct selector).
#
# WHY THIS EXISTS AS A GATE. AFD-114 bumped the pin to 0.64.0 on the strength of a
# two-binary differential, and clean-room verification pointed out that the evidence —
# including the "the control fires" half that makes the byte-identical result non-vacuous —
# lived ONLY as prose in a findings file. Nothing could re-run it. This can.
#
# The signature is specific rather than a version check: in the BUGGY lowering the join
# writes the param's home register, so the final add has that register as BOTH operands
# (`adds rN, r0, r0`). In the fixed lowering the then-arm copies the home into a temp first
# and the add reads two DIFFERENT registers. This module never legitimately doubles param 0
# — the correct answer is 5 + a — so a same-register add of r0 is the defect and nothing else.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/../../.." && pwd -P)"
SYNTH="${SYNTH:-$ROOT/.scratch/synthpin/synth}"
OUT="${OUT:-$(mktemp -d)}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -x "$SYNTH" ] || fail "synth not executable at $SYNTH"
command -v wasm-tools >/dev/null || fail "wasm-tools not on PATH"

"${WASM_TOOLS:-wasm-tools}" parse "$D/joinalias.wat" -o "$OUT/j.wasm" || fail "wasm-tools parse"
"$SYNTH" compile "$OUT/j.wasm" -t cortex-m3 --cortex-m --relocatable --all-exports \
    -o "$OUT/j.o" >"$OUT/lower.log" 2>&1 || { cat "$OUT/lower.log"; fail "control did not lower"; }

# Disassemble with arm-none-eabi-objdump, NOT `synth disasm`.
#
# The first version used `synth disasm` and captured stdout only. That passed locally and
# FAILED IN CI with "no 'adds' in the disassembly" — synth writes its disassembly and its INFO
# log across both streams, and the split is not the same on the Linux build. The vacuity guard
# below caught it rather than letting an empty capture report a pass, which is the one thing
# that had to work. objdump is deterministic, is already a preflight dependency of the job that
# runs this, and does not change format between hosts.
command -v arm-none-eabi-objdump >/dev/null || fail "arm-none-eabi-objdump not on PATH"
dis="$(arm-none-eabi-objdump -d "$OUT/j.o" 2>/dev/null)"
# The disassembly must be non-empty AND contain the add, or the grep below would pass
# vacuously on an empty string — the failure this repo keeps finding in checkers.
echo "$dis" | grep -qE '\badds\b' \
  || fail "no 'adds' in the disassembly — the check would be vacuous
$dis"

bad="$(echo "$dis" | grep -E '\badds\s+r[0-9]+,\s*r0,\s*r0\b' || true)"
if [ -n "$bad" ]; then
  echo "$bad"
  fail "synth#1189 SIGNATURE PRESENT: the join wrote param 0's home register, so the add
   takes it as both operands. This lowering computes a + a instead of 5 + a — exit 0,
   wrong answer. $("$SYNTH" --version 2>&1 | head -1)"
fi
echo "synth#1189 absent: the join does not alias param 0's home ($("$SYNTH" --version 2>&1 | head -1))"
echo "$dis" | grep -E '\badds\b' | sed 's/^/   /'
