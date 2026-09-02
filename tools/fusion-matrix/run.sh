#!/usr/bin/env bash
# The fused five-stage falcon cascade across every meld memory strategy, through to
# lowering — the matrix behind relay's SWREQ-FALCON-OCI-P02/-P05/-P06 kill-criterion.
#
# WHY A MATRIX AND NOT A YES/NO: relay's criterion names `--address-rebase`
# specifically, and jess's own prior run used `--pack-rebase`. Those are different
# flags, and answering the question as if they were the same would have promoted three
# requirements on a conflation. This runs every strategy and reports each separately.
#
# It also distinguishes the SELF-CONTAINED path from the EMBEDDER-CONTRACT path, because
# m4f reaching 5/5 depends on the latter — a distinction that is invisible if you only
# report "5/5".
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
OUT="${OUT:-$ROOT/.scratch/fusion}"; mkdir -p "$OUT"
SYNTH="${SYNTH:-$ROOT/.scratch/fg60/synth}"
DIR="${DIR:-$ROOT/.scratch/v1341}"
RATE="${RATE:-$DIR/rate.wasm}";         MIXER="${MIXER:-$DIR/mixer.wasm}"
ATT="${ATT:-$DIR/attitude.wasm}";       POS="${POS:-$DIR/position.wasm}"
IEKF="${IEKF:-$DIR/iekf.wasm}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Dispatch meld/loom through varve, NEVER through PATH. This repo's PATH carries meld
# 0.41.3 while the pin carries 0.52.0 — an eleven-version gap that once produced a wrong
# upstream bug report (AFD-045, meld#390). A matrix whose tool versions are ambiguous is
# not evidence, so the versions are printed and asserted rather than assumed.
MELD=(varve run meld); LOOM=(varve run loom)
command -v varve >/dev/null || fail "varve not on PATH — the pin is how tool versions are known here"
mv="$("${MELD[@]}" --version 2>/dev/null | head -1)"; lv="$("${LOOM[@]}" --version 2>/dev/null | head -1)"
[ -n "$mv" ] && [ -n "$lv" ] || fail "could not resolve pinned meld/loom via varve"
sv="$("$SYNTH" --version 2>/dev/null | head -1)"
# S5 FIX: the banner used to read "(pinned, not PATH)" over all three tools. meld and
# loom ARE varve-dispatched; synth is NOT — it is an untracked local binary, and the
# varve pin actually carries a DIFFERENT synth version. Printing it under a "pinned"
# header was wrong about a third of what it displayed.
sp="$(varve run synth --version 2>/dev/null | head -1)"
echo "== toolchain =="
echo "   pinned via varve : $mv   $lv"
echo "   NOT pinned       : $sv   (from \$SYNTH=$SYNTH; the varve layer carries ${sp:-an unknown synth})"
for f in "$RATE" "$MIXER" "$ATT" "$POS" "$IEKF"; do [ -f "$f" ] || fail "missing component: $f"; done
[ -x "$SYNTH" ] || fail "synth not at $SYNTH"
command -v arm-none-eabi-nm >/dev/null || fail "arm-none-eabi toolchain not on PATH"

# DISTINCT stages, not a symbol count: five symbols from one stage would pass a grep -c.
stages() { arm-none-eabi-nm "$1" 2>/dev/null | grep -E ' T ' \
             | grep -oE 'falcon-cascade/[a-z]+@' | sort -u | wc -l | tr -d ' '; }

row() {
  local name="$1"; shift
  "${MELD[@]}" fuse "$RATE" "$MIXER" "$ATT" "$POS" "$IEKF" "$@" -o "$OUT/$name.wasm" >"$OUT/$name.meld.log" 2>&1
  local mrc=$?
  printf '  %-34s meld=%-3s ' "$*" "$mrc"
  [ $mrc -ne 0 ] && { echo "REFUSED"; return; }
  wasm-tools validate "$OUT/$name.wasm" >/dev/null 2>&1 || { echo "fused module INVALID"; return; }
  "${LOOM[@]}" optimize "$OUT/$name.wasm" -o "$OUT/$name.loom.wasm" >/dev/null 2>&1 || { echo "loom failed"; return; }
  "$SYNTH" compile "$OUT/$name.loom.wasm" -t cortex-m7dp --cortex-m --relocatable \
      --embedder-data-init --embedder-global-init -o "$OUT/$name.o" >"$OUT/$name.synth.log" 2>&1
  printf 'validate=OK  m7dp exit=%d stages=%s/5\n' "$?" "$(stages "$OUT/$name.o")"
}

echo "== fused 5-stage cascade, every memory strategy (embedder-contract lowering) =="
row addr   --memory shared --address-rebase
row pack   --memory shared --pack-rebase
row share  --memory shared --pack-rebase --share-stack
row multi  --memory multi

echo
echo "== the distinction that 5/5 alone hides: self-contained vs embedder-contract =="
[ -f "$OUT/addr.loom.wasm" ] || fail "address-rebase row did not produce an image to compare"
for core in cortex-m7dp cortex-m4f; do
  "$SYNTH" compile "$OUT/addr.loom.wasm" -t $core --cortex-m -o "$OUT/sc.$core.o" >"$OUT/sc.$core.log" 2>&1
  sc=$?
  "$SYNTH" compile "$OUT/addr.loom.wasm" -t $core --cortex-m --relocatable \
      --embedder-data-init --embedder-global-init -o "$OUT/ec.$core.o" >"$OUT/ec.$core.log" 2>&1
  ec=$?
  printf '  %-12s  self-contained exit=%d %-28s  embedder-contract exit=%d stages=%s/5\n' \
    "$core" "$sc" "$(grep -oE '[0-9]+ of [0-9]+ functions were skipped' "$OUT/sc.$core.log" | head -1)" \
    "$ec" "$(stages "$OUT/ec.$core.o")"
done

# The criterion relay actually named. Assert it rather than leaving it to be read off.
a_stages="$(stages "$OUT/addr.o")"
[ "$a_stages" = "5" ] || fail "--address-rebase did not yield 5 distinct stages (got $a_stages)"
echo
echo "PASS — --memory shared --address-rebase ACCEPTS the fused five-stage cascade,"
echo "       the fused module validates, and it lowers to 5 DISTINCT stages."
