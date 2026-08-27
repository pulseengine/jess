#!/usr/bin/env bash
# Lower the FULL 5-stage falcon cascade for cortex-m4f and cortex-m7dp, then LINK the
# m4f object — because "it lowers" is not "it works", and an object with unresolved
# externals is not a shippable image.
#
# WHAT THIS ESTABLISHES (AFD-046): the M4-portability half of GI-FPU-002 is resolved in
# synth v0.60 via the relocatable + embedder-contract path, and jess's obligation as the
# embedder is exactly THREE AEABI symbols, all present in the stock ARM toolchain.
#
# The plain self-contained path still declines 3 functions on m4f — that is NOT a defect,
# it is synth honestly refusing to emit f64 on a single-precision FPU (#369). The fix is
# to route those i64<->f32 conversions through the AEABI builtins, which is what
# --relocatable does, and to accept the two embedder obligations synth then names.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
OUT="${OUT:-$ROOT/.scratch/m4matrix}"; mkdir -p "$OUT"
SYNTH="${SYNTH:-$ROOT/.scratch/fg60/synth}"
FUSED="${FUSED:?set FUSED to a loom-optimised fused cascade .wasm}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -x "$SYNTH" ] || fail "synth not found at $SYNTH (campaign uses v0.60; the varve layer carries 0.58)"
command -v arm-none-eabi-nm >/dev/null || fail "arm-none-eabi toolchain not on PATH"

echo "== 1. lower, declaring the embedder contract =="
# --embedder-data-init  (#1041) jess populates memory 0's active data segments
# --embedder-global-init(#1052) jess seeds the R9 globals table from the module's initialisers
# Neither flag changes a single emitted byte; each converts a REFUSAL into an explicit
# acknowledgement. They are promises jess must actually keep at instantiation.
for core in cortex-m7dp cortex-m4f; do
  "$SYNTH" compile "$FUSED" -t $core --cortex-m --relocatable \
      --embedder-data-init --embedder-global-init -o "$OUT/$core.o" >"$OUT/$core.log" 2>&1 \
    || { sed -n 's/^Error: /  /p' "$OUT/$core.log" | head -2; fail "$core did not lower"; }
  n=$("$ROOT/tools/lowering/_count_exports.sh" "$OUT/$core.o")
  echo "   $core: exit 0, $n/5 cascade stages exported"
  [ "$n" = "5" ] || fail "$core exported $n/5 stages"
done

echo "== 2. m4f external symbols (the embedder's link obligation) =="
# NOT `mapfile` — it does not exist in macOS's bash 3.2, and its absence here silently
# printed "<none>" for a symbol list that actually had three entries.
undef="$(arm-none-eabi-nm "$OUT/cortex-m4f.o" | awk '$1=="U"||$2=="U"{print $NF}' | sort -u)"
undef_n=$(printf '%s\n' "$undef" | grep -c . || true)
[ "$undef_n" -gt 0 ] || fail "m4f needs NO external symbols — unexpected; the AEABI route did not engage"
printf '%s\n' "$undef" | sed 's/^/   /' 

echo "== 3. m7dp must need NONE (it has a double-precision FPU) =="
m7u=$(arm-none-eabi-nm "$OUT/cortex-m7dp.o" | awk '$1=="U"||$2=="U"{print $NF}' | sort -u | wc -l | tr -d ' ')
[ "$m7u" = "0" ] || fail "m7dp unexpectedly needs external symbols ($m7u)"
echo "   confirmed: 0 external symbols"

echo "== 4. LINK m4f against libgcc — proves the obligation is satisfiable =="
LG=$(arm-none-eabi-gcc -mcpu=cortex-m4 -mfpu=fpv4-sp-d16 -mfloat-abi=hard -print-libgcc-file-name)
arm-none-eabi-ld -r "$OUT/cortex-m4f.o" "$LG" -o "$OUT/m4f.linked.o" || fail "link failed"
left=$(arm-none-eabi-nm "$OUT/m4f.linked.o" | awk '$1=="U"||$2=="U"{print $NF}' | sort -u)
[ -z "$left" ] || fail "still unresolved after linking libgcc: $left"
n=$("$ROOT/tools/lowering/_count_exports.sh" "$OUT/m4f.linked.o")
[ "$n" = "5" ] || fail "linked object lost stages ($n/5) — an empty nm is not a pass"
echo "   linked clean, 0 undefined, $n/5 stages still present"

echo "== 5. NEGATIVE CONTROL: without libgcc the symbols MUST stay undefined =="
arm-none-eabi-ld -r "$OUT/cortex-m4f.o" -o "$OUT/m4f.nolibgcc.o" 2>/dev/null
nleft=$(arm-none-eabi-nm "$OUT/m4f.nolibgcc.o" | awk '$1=="U"||$2=="U"{print $NF}' | sort -u | wc -l | tr -d ' ')
[ "$nleft" -gt 0 ] || fail "VACUOUS: linking without libgcc left nothing undefined — step 4 proves nothing"
echo "   confirmed: $nleft undefined without libgcc, so step 4 was a real resolution"

echo
echo "PASS — full cascade lowers 5/5 on m7dp AND m4f; m4f's obligation is $undef_n AEABI"
echo "       symbol(s), resolved by the stock ARM toolchain, negative-controlled."
