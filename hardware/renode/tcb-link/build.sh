#!/usr/bin/env bash
# DD-018 TCB-LINK model — minimal end-to-end demonstration + LINK oracle.
# Proves the gale-maximal-wasm on-target linking model INDEPENDENT of the falcon
# #369/#275 poles: a wasm module compiled `--relocatable --native-pointer-abi`
# emits an ELF ET_REL whose ONLY undefined symbols are its host imports (the TCB
# seam); a thin NATIVE TCB shim provides them; the two link into a complete,
# base-independent Cortex-M image. This is the DD-018 path (vs the self-contained
# --cortex-m ELF), demonstrated on a minimal example.
#
# ORACLE (exits non-zero on failure): the linked ELF has ZERO undefined symbols
# (the seam is fully resolved) and is an ARM executable.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
SYNTH="${SYNTH:?set SYNTH to a synth binary}"
CC="${CC:-arm-none-eabi-gcc}"; LD="${LD:-arm-none-eabi-ld}"; NM="${NM:-arm-none-eabi-nm}"
WT="${WASM_TOOLS:-wasm-tools}"

"$WT" parse "$D/seam.wat" -o "$D/seam.wasm"
# The DD-018 recipe (the ABI gust uses): base-independent, host-pointer drop-in.
"$SYNTH" compile "$D/seam.wasm" -t cortex-m7dp --relocatable --native-pointer-abi \
    --shadow-stack-size 1024 -o "$D/seam.o" >/dev/null 2>&1
echo "seam.o (synth --relocatable --native-pointer-abi): TCB seam = undefined symbols:"
"$NM" "$D/seam.o" | grep ' U ' || true
"$CC" -c -mcpu=cortex-m7 -mthumb "$D/tcb.S" -o "$D/tcb.o"
"$LD" -T "$D/link.ld" "$D/tcb.o" "$D/seam.o" -o "$D/tcb-link.elf"
undef=$("$NM" "$D/tcb-link.elf" | grep -c ' U ' || true)
[ "$undef" = "0" ] || { echo "LINK FAIL: $undef undefined symbols remain after TCB-link" >&2; exit 1; }
file "$D/tcb-link.elf" | grep -q "ARM" || { echo "LINK FAIL: not an ARM ELF" >&2; exit 1; }
echo "LINK OK — DD-018 TCB seam fully resolved: wasm(compute) + native(tcb_seed) -> complete ARM image, 0 undefined."
