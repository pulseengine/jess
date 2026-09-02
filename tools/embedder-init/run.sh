#!/usr/bin/env bash
# Extract the initialisation state a synth --relocatable image does not carry, and
# verify it against INDEPENDENT sources.
#
# WHY THIS EXISTS: AFD-046 lowered the full cascade for cortex-m4f by declaring two
# obligations to synth — --embedder-data-init (#1041) and --embedder-global-init
# (#1052). Those flags emit BYTE-IDENTICAL code; they convert a refusal into an
# acknowledgement and nothing else. They are promises. Unkept, every load from the
# initialised region and every global.get reads whatever the target memory holds.
# This turns the promise into linkable data plus a check that it is right.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
OUT="${OUT:-$ROOT/.scratch/einit}"; mkdir -p "$OUT"
PY="${PY:-python3}"
MOD="${MOD:?set MOD to the fused, loom-optimised module}"
SYNTH="${SYNTH:-$ROOT/.scratch/fg60/synth}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -f "$MOD" ] || fail "module not found: $MOD"
command -v wasm-tools >/dev/null || fail "wasm-tools not on PATH"
# The verifier needs the wasmtime PYTHON module, which is not the wasmtime CLI.
# Omitting this check is how a sibling oracle died mid-run with a bare ImportError.
"$PY" -c 'import wasmtime' 2>/dev/null || fail \
  "the Python module 'wasmtime' is missing for: $PY
   install:  $PY -m pip install -r $ROOT/tools/cascade-differential/requirements.txt"

echo "== extract =="
"$PY" "$ROOT/tools/embedder-init/extract_init.py" "$MOD" \
    --out-c "$OUT/jess_wasm_init.c" --out-manifest "$OUT/init.json" || fail "extraction failed"

echo "== verify against independent sources =="
# Data segments are checked against wasmtime's OWN instantiated memory; globals against
# a raw binary parse of the global section. Neither re-reads the extractor's parse — a
# verifier that did would prove only that the parser agrees with itself.
"$PY" "$ROOT/tools/embedder-init/verify_init.py" "$MOD" "$OUT/init.json" "$OUT/jess_wasm_init.c" \
    || fail "extracted init does not match the module"

# --- S1 FIX: the object is LOWERED FROM `MOD` HERE, never accepted from outside.
#
# The previous version took an OBJ= path and never bound it to MOD. Clean-room
# verification handed it a module fused with --pack-rebase and an object lowered from
# a DIFFERENT module fused with --address-rebase — segment offsets differing by
# 226,624 bytes — and this oracle reported PASS. Applying those tables to that image
# would corrupt every initialised load.
#
# The old negative control ("a bogus object -> link failed") only ruled out GARBAGE.
# A well-formed object from the wrong module passed, which is exactly the failure
# class AFD-048 and AFD-049 were about. Binding by construction is the fix: an
# externally-supplied object cannot be checked for provenance the emitted tables do
# not carry, so it is no longer accepted.
if [ -n "${LOWER:-}" ]; then
  echo "== lower $MOD for $LOWER and link the init against THAT object =="
  command -v arm-none-eabi-gcc >/dev/null || fail "LOWER given but arm-none-eabi-gcc is not on PATH"
  [ -x "$SYNTH" ] || fail "LOWER given but synth not found at $SYNTH (set SYNTH=)"
  "$SYNTH" compile "$MOD" -t "$LOWER" --cortex-m --relocatable \
      --embedder-data-init --embedder-global-init -o "$OUT/lowered.o" >"$OUT/lower.log" 2>&1 \
    || { sed -n 's/^Error: /  /p' "$OUT/lower.log" | head -2; fail "$MOD did not lower for $LOWER"; }
  case "$LOWER" in
    cortex-m4f)  CPU="-mcpu=cortex-m4 -mfpu=fpv4-sp-d16 -mfloat-abi=hard" ;;
    cortex-m7dp) CPU="-mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard" ;;
    *) fail "unmapped LOWER target: $LOWER" ;;
  esac
  arm-none-eabi-gcc -c $CPU -ffreestanding -O2 "$OUT/jess_wasm_init.c" -o "$OUT/init.o" \
    || fail "the emitted init does not COMPILE for $LOWER"
  LG="$(arm-none-eabi-gcc $CPU -print-libgcc-file-name)"
  arm-none-eabi-ld -r "$OUT/lowered.o" "$OUT/init.o" "$LG" -o "$OUT/linked.o" || fail "link failed"
  left="$(arm-none-eabi-nm "$OUT/linked.o" | awk '$1=="U"||$2=="U"{print $NF}' | sort -u)"
  [ -z "$left" ] || fail "undefined after linking: $left"
  # An empty object also prints no undefined symbols, so count what SURVIVED.
  ntab=$(arm-none-eabi-nm "$OUT/linked.o" | grep -c 'jess_wasm_' || true)
  nstage=$(arm-none-eabi-nm "$OUT/linked.o" | grep -cE ' T .*pulseengine:falcon-cascade' || true)
  [ "$ntab" -ge 5 ]   || fail "init tables missing from the linked object ($ntab/5)"
  [ "$nstage" -ge 1 ] || fail "no cascade stage survived the link"
  echo "   lowered from THIS module, compiled freestanding, linked clean:"
  echo "   0 undefined, $ntab init symbol(s), $nstage cascade stage(s)"
fi
if [ -n "${OBJ:-}" ]; then
  fail "OBJ= is no longer accepted: an external object cannot be bound to MOD, and an
   object from a DIFFERENT fusion once passed this oracle with offsets 226,624 bytes
   apart. Use LOWER=cortex-m4f (or cortex-m7dp) so the object is lowered from MOD here."
fi

echo
echo "PASS — the embedder-init tables reproduce wasmtime's instantiated memory byte for"
echo "       byte, and the globals agree with the raw binary section."
echo "       $OUT/jess_wasm_init.c is the linkable form."
