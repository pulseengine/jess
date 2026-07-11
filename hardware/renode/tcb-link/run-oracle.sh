#!/usr/bin/env bash
# DD-018 TCB-link EXECUTION oracle (the rung above build.sh's LINK oracle).
#
# build.sh proves the fused image LINKS (0 undefined symbols after the native TCB
# shim satisfies the wasm import seam). This proves it EXECUTES on emulated RT1176
# Cortex-M7: the synth `--relocatable --native-pointer-abi` wasm export `compute`
# runs on real ARM, calls the native primitive `tcb_seed` (0xCAFE), and stores
# compute()=tcb_seed()+1=0xCAFF to DTCM @0x20010000 — the DD-018 gale-maximal-wasm
# on-target model, end-to-end, INDEPENDENT of the falcon #369/#275 float poles.
#
# ORACLE (exits non-zero on failure): DTCM @0x20010000 == 0x0000CAFF after boot.
# NEGATIVE CONTROL: before execution the same word is 0x00000000 (DTCM zeroed) —
# so 0xCAFF can only come from compute() actually running. See README "Rung 2".
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/../../.." && pwd)"   # repo root: boot.resc uses @hardware/... (repo-root-relative, matching CI)
RENODE="${RENODE:-/Users/r/renode-1.16.1/Contents/MacOS/renode}"
ELF="$D/tcb-link.elf"

[ -x "$RENODE" ] || { echo "EXEC ORACLE SKIP: renode not found at $RENODE (set RENODE=...)" >&2; exit 2; }
[ -f "$ELF" ]    || { echo "EXEC ORACLE FAIL: $ELF missing — run build.sh first" >&2; exit 1; }

# Renode resolves @paths against its CWD; boot.resc uses repo-root-relative paths.
out="$(cd "$ROOT" && "$RENODE" --console --disable-xwt -e "include @hardware/renode/tcb-link/boot.resc
quit" 2>&1)"

val="$(printf '%s\n' "$out" | grep -A1 TCB_EXEC_WORD_BEGIN | grep -oiE '0x0000CAFF' | head -1 || true)"
if [ "$val" != "0x0000CAFF" ]; then
  echo "EXEC ORACLE FAIL: expected 0x0000CAFF at DTCM 0x20010000, image did not execute cleanly" >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 1
fi
echo "EXEC OK — DD-018 image runs on RT1176 Cortex-M7: wasm compute()=tcb_seed()+1=0xCAFF observed in DTCM."
