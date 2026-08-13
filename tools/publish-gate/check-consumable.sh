#!/usr/bin/env bash
# check-consumable.sh — assert a published wasm component is actually consumable
# by the MCU lowering chain (meld fuse --memory shared --pack-rebase -> loom -> synth).
#
# Every check here corresponds to a real defect that reached a consumer:
#   C1 component header   — falcon-rate:1.129.0 shipped as a CORE MODULE past a green
#                           publish step (config.mediaType says "component" regardless).
#   C2 no memory.grow     — blocks meld shared-memory fusion outright (meld#299).
#   C3 no WASI imports    — WASI imports do not lower to bare metal.
#   C4 reloc metadata     — without linking/reloc.*, --address-rebase REJECTS (meld: addends,
#                           not final addresses). Needs -C link-arg=--emit-relocs on the FINAL link.
#   C5 __heap_base        — without it --pack-rebase cannot see .bss above the last data segment
#                           and would under-reserve silently (meld#370). Needs the `linking`
#                           section retained through `wasm-tools component new`.
#
# Usage: check-consumable.sh <file.wasm> [more.wasm ...]
# Exit 0 only if every file passes every check.
set -uo pipefail
command -v wasm-tools >/dev/null || { echo "FATAL: wasm-tools not on PATH"; exit 2; }

rc=0
for f in "$@"; do
  [ -f "$f" ] || { echo "FATAL: no such file: $f"; exit 2; }
  name=$(basename "$f")
  fail=0
  hdr=$(head -c 8 "$f" | xxd -p)
  wat=$(wasm-tools print "$f" 2>/dev/null)

  [ "$hdr" = "0061736d0d000100" ] && c1=PASS || { c1="FAIL(core-module:$hdr)"; fail=1; }
  n=$(printf '%s' "$wat" | grep -c 'memory\.grow')
  [ "$n" -eq 0 ] && c2=PASS || { c2="FAIL($n memory.grow)"; fail=1; }
  n=$(printf '%s' "$wat" | grep -c 'wasi:')
  [ "$n" -eq 0 ] && c3=PASS || { c3="FAIL($n wasi imports)"; fail=1; }
  n=$(printf '%s' "$wat" | grep -cE '@custom "(linking|reloc\.)')
  [ "$n" -gt 0 ] && c4=PASS || { c4="FAIL(no linking/reloc.* — need --emit-relocs on FINAL link)"; fail=1; }
  printf '%s' "$wat" | grep -q '__heap_base' && c5=PASS || { c5="FAIL(no __heap_base — retain linking section)"; fail=1; }

  [ $fail -eq 0 ] && verdict="CONSUMABLE" || { verdict="NOT CONSUMABLE"; rc=1; }
  printf '%-28s %s\n' "$name" "$verdict"
  printf '    C1 component-header  %s\n    C2 no-memory.grow    %s\n    C3 no-wasi           %s\n    C4 reloc-metadata    %s\n    C5 __heap_base       %s\n' "$c1" "$c2" "$c3" "$c4" "$c5"
done
exit $rc
