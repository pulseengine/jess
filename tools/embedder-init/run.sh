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
MOD="${MOD:?set MOD to the fused, loom-optimised module the ARM object was lowered from}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -f "$MOD" ] || fail "module not found: $MOD"
command -v wasm-tools >/dev/null || fail "wasm-tools not on PATH"
# The verifier needs the wasmtime PYTHON module, which is not the wasmtime CLI.
# Omitting this check is how a sibling oracle died mid-run with a bare ImportError.
"$PY" -c 'import wasmtime' 2>/dev/null || fail \
  "the Python module 'wasmtime' is missing for: $PY
   install:  $PY -m pip install -r $ROOT/tools/cascade-differential/requirements.txt"

# AFD-053 S2: verify the external artifacts against tools/deps/artifacts.pins BEFORE
# measuring anything. Without this the oracle runs against whatever happens to be in
# .scratch/ and reports a result that reads reproducible and is not.
"$ROOT/tools/deps/check.sh" >/dev/null 2>&1 || {
  "$ROOT/tools/deps/check.sh" >&2
  fail "external artifacts do not match tools/deps/artifacts.pins (see above)"
}

echo "== extract =="
"$PY" "$ROOT/tools/embedder-init/extract_init.py" "$MOD" \
    --out-c "$OUT/jess_wasm_init.c" --out-manifest "$OUT/init.json" || fail "extraction failed"

echo "== verify against independent sources =="
# Data segments are checked against wasmtime's OWN instantiated memory; globals against
# a raw binary parse of the global section. Neither re-reads the extractor's parse — a
# verifier that did would prove only that the parser agrees with itself.
"$PY" "$ROOT/tools/embedder-init/verify_init.py" "$MOD" "$OUT/init.json" "$OUT/jess_wasm_init.c" \
    || fail "extracted init does not match the module"

# --- optional but NOT skippable-in-silence: if an ARM object is named, prove the
# emitted C actually compiles for that target and links against it with nothing left
# undefined. "the linkable form" is a claim, and this is what makes it one that fails.
if [ -n "${OBJ:-}" ]; then
  echo "== compile for the target and link against $OBJ =="
  [ -f "$OBJ" ] || fail "OBJ not found: $OBJ"
  command -v arm-none-eabi-gcc >/dev/null || fail "OBJ given but arm-none-eabi-gcc is not on PATH"
  CPU="${CPU:--mcpu=cortex-m4 -mfpu=fpv4-sp-d16 -mfloat-abi=hard}"
  # -ffreestanding: the emitted C deliberately pulls no libc headers, because the
  # cross toolchain may ship none (homebrew's does not).
  arm-none-eabi-gcc -c $CPU -ffreestanding -O2 "$OUT/jess_wasm_init.c" -o "$OUT/init.o"     || fail "the emitted init does not COMPILE for this target"
  LG="$(arm-none-eabi-gcc $CPU -print-libgcc-file-name)"
  arm-none-eabi-ld -r "$OBJ" "$OUT/init.o" "$LG" -o "$OUT/linked.o"     || fail "link failed"
  left="$(arm-none-eabi-nm "$OUT/linked.o" | awk '$1=="U"||$2=="U"{print $NF}' | sort -u)"
  [ -z "$left" ] || fail "undefined after linking: $left"
  # An empty object also prints no undefined symbols, so count what SURVIVED.
  ntab=$(arm-none-eabi-nm "$OUT/linked.o" | grep -c 'jess_wasm_' || true)
  nstage=$(arm-none-eabi-nm "$OUT/linked.o" | grep -cE ' T .*pulseengine:falcon-cascade' || true)
  [ "$ntab" -ge 5 ] || fail "init tables missing from the linked object ($ntab/5)"
  [ "$nstage" -ge 1 ] || fail "no cascade stage survived the link — an empty object also shows 0 undefined"
  echo "   compiled freestanding, linked clean: 0 undefined, $ntab init symbol(s), $nstage cascade stage(s)"
fi

echo
echo "PASS — the embedder-init tables reproduce wasmtime's instantiated memory byte for"
echo "       byte, and the globals agree with the raw binary section."
echo "       $OUT/jess_wasm_init.c is the linkable form."
