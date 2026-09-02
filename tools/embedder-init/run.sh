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

echo "== extract =="
"$PY" "$ROOT/tools/embedder-init/extract_init.py" "$MOD" \
    --out-c "$OUT/jess_wasm_init.c" --out-manifest "$OUT/init.json" || fail "extraction failed"

echo "== verify against independent sources =="
# Data segments are checked against wasmtime's OWN instantiated memory; globals against
# a raw binary parse of the global section. Neither re-reads the extractor's parse — a
# verifier that did would prove only that the parser agrees with itself.
"$PY" "$ROOT/tools/embedder-init/verify_init.py" "$MOD" "$OUT/init.json" "$OUT/jess_wasm_init.c" \
    || fail "extracted init does not match the module"

echo
echo "PASS — the embedder-init tables reproduce wasmtime's instantiated memory byte for"
echo "       byte, and the globals agree with the raw binary section."
echo "       $OUT/jess_wasm_init.c is the linkable form."
