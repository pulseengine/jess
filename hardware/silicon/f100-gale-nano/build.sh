#!/usr/bin/env bash
# Link gale-nano 0.7.0 for the STM32F100 and gate the result (H3 second half).
#
#   gale-nano (PINNED oci artifact) -> synth --relocatable --embedder-data-init
#     --embedder-global-init -t cortex-m3
#   + jess's REAL gust:hal read32/write32 (AFD-109)
#   + jess's generic embedder-init apply loop (AFD-107)
#   + gust_os_embed.S — jess's HARNESS for the gust:os seam, not an implementation
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$D/../../.." && pwd -P)"
OUT="${OUT:-$ROOT/.scratch/f100gale}"; mkdir -p "$OUT"
SYNTH="${SYNTH:?set SYNTH to a synth binary}"
PY="${PY:-python3}"
GALE="${GALE:-$ROOT/.scratch/galenano7/gale-nano-0.7.0.wasm}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v arm-none-eabi-gcc >/dev/null || fail "arm-none-eabi-gcc not on PATH"
[ -f "$GALE" ] || fail "gale-nano artifact not found: $GALE"

# The artifact must be the PINNED one. A differential against an unpinned gale-nano is a
# result about whatever happened to be in .scratch.
# READ the expected digest from artifacts.pins rather than carrying a second copy here.
# Two hardcoded hashes that agree today, with nothing enforcing that they keep agreeing, is
# the drifted-mirror shape AFD-104 deleted a registry for. Found by clean-room verification.
want=$(awk '$1=="galenano7/gale-nano-0.7.0.wasm"{print $2; exit}' "$ROOT/tools/deps/artifacts.pins")
[ ${#want} -eq 64 ] || fail "could not read the gale-nano digest from tools/deps/artifacts.pins
   (got '${want}') — refusing to verify against a digest this script invented"
got=$(shasum -a 256 "$GALE" 2>/dev/null | awk '{print $1}')
[ -z "$got" ] && got=$(sha256sum "$GALE" | awk '{print $1}')
[ "$got" = "$want" ] || fail "gale-nano is not the pinned artifact
   want $want
   got  $got"
echo "gale-nano: pinned artifact verified ($want)"

"$SYNTH" compile "$GALE" -t cortex-m3 --cortex-m --relocatable --all-exports \
    --embedder-data-init --embedder-global-init -o "$OUT/gale.o" >"$OUT/lower.log" 2>&1 \
  || { tail -3 "$OUT/lower.log"; fail "gale-nano did not lower for cortex-m3"; }
# Wire gale-nano's intra-component imports to its OWN exports. See gust_os_embed.S.
# Renaming is the only route: the export names contain `@`, which begins an ARM comment,
# so they cannot be referenced from a .S label at all.
arm-none-eabi-objcopy \
  --redefine-sym 'gust:sched/tasks@0.1.0#set-deadline=set-deadline' \
  --redefine-sym 'gust:sched/tasks@0.1.0#slept-status=slept-status' \
  --redefine-sym 'gust:sched/tasks@0.1.0#state=state' \
  "$OUT/gale.o" "$OUT/gale.aliased.o" || fail "objcopy --redefine-sym failed"
for s in set-deadline slept-status state; do
  arm-none-eabi-nm "$OUT/gale.aliased.o" | grep -qE "^[0-9a-f]+ T $s\$" \
    || fail "'$s' is not DEFINED after aliasing — gale-nano's own export did not get renamed"
done
mv "$OUT/gale.aliased.o" "$OUT/gale.o"
echo "sched imports aliased to gale-nano's own exports (3)"

n=$(grep -ci 'skip' "$OUT/lower.log" || true)
[ "$n" = "0" ] || { cat "$OUT/lower.log"; fail "$n skip line(s) — the image is incomplete"; }

# The gust:os seam must BE a seam. If these stopped being undefined, gale-nano would be
# calling something other than jess's harness and the differential would measure nothing.
# EXACT set, not membership. The previous check asserted these three ARE undefined and
# said "the 3 jess genuinely owes", but never that they are the ONLY ones — so a lowering
# that grew a seventh obligation would have passed while the message kept claiming three.
# UNRESOLVED = undefined MINUS defined, within this one object.
#
# `nm` lists all SIX as undefined even after the aliasing, because --redefine-sym renames the
# definition to the imported name and the object then carries BOTH a T and a U entry for it;
# the linker resolves them internally. So the raw U list is NOT "what the embedder owes", and
# a check written against it either expects six (and silently tolerates the aliasing breaking)
# or expects three (and fails on a correct build). Writing this assertion is what surfaced
# that — the earlier membership check could not have.
und="$(arm-none-eabi-nm "$OUT/gale.o" | awk '$1=="U"||$2=="U"{print $NF}' | sort -u)"
def_="$(arm-none-eabi-nm "$OUT/gale.o" | awk '$2=="T"||$2=="t"||$2=="W"{print $3}' | sort -u)"
got="$(comm -23 <(printf '%s\n' "$und") <(printf '%s\n' "$def_") | tr '\n' ' ')"
[ "$got" = "deadline poll-task read32 " ] \
  || fail "the embedder seam is not the expected set.
   expected (unresolved): deadline poll-task read32
   got:                   $got
   (3 of gale-nano's 6 lowered imports are its OWN exports, aliased above and resolved inside
    the object; a change here means synth's lowering moved or the aliasing stopped resolving.)"
echo "embedder seam is EXACTLY: poll-task, deadline, read32 (the 3 jess genuinely owes)"

"$PY" "$ROOT/tools/embedder-init/extract_init.py" "$GALE" \
    --out-c "$OUT/init_tables.c" --out-manifest "$OUT/init.json" >"$OUT/einit.log" 2>&1 \
  || { cat "$OUT/einit.log"; fail "init extraction failed"; }
segs=$($PY -c "import json;print(len(json.load(open('$OUT/init.json'))['segments']))")
globs=$($PY -c "import json;print(len(json.load(open('$OUT/init.json'))['globals']))")
[ "$segs" -gt 0 ] && [ "$globs" -gt 0 ] || fail "empty init tables — a vacuous instantiation"
echo "init tables: $segs segment(s), $globs global(s)"

# The image must FIT the real part: linear memory base 0x20000600 + 0x1000 must stay under
# 0x20002000, and every declared segment must land inside it. AFD-088 is why this is checked
# rather than assumed — an emulator sized to the artifact hid a 6-week-old misfit.
top=$($PY -c "import json;d=json.load(open('$OUT/init.json'));print(max((s['offset']+s['len']) for s in d['segments']))")
[ "$top" -le 4096 ] || fail "highest data address $top exceeds the 4096 B linear-memory window"
echo "geometry: highest data address $top B <= 4096 B window (real 8 KB part)"

CPU="-mcpu=cortex-m3 -mthumb"
arm-none-eabi-gcc -c $CPU -ffreestanding -O2 "$OUT/init_tables.c" -o "$OUT/tables.o"   || fail "tables did not compile"
arm-none-eabi-gcc -c $CPU -ffreestanding -O2 -ffixed-r9 -ffixed-r10 -ffixed-r11 \
    "$ROOT/hardware/silicon/f100-init/apply_init.c" -o "$OUT/apply.o"                  || fail "apply loop did not compile"
arm-none-eabi-gcc -c $CPU -ffreestanding -O2 -ffixed-r9 -ffixed-r10 -ffixed-r11 \
    "$ROOT/hardware/silicon/f100-gust-hal/gust_hal.c" -o "$OUT/hal.o"                  || fail "gust_hal did not compile"
arm-none-eabi-gcc -c $CPU "$D/gust_os_embed.S" -o "$OUT/embed.o"                       || fail "embedder harness did not assemble"
arm-none-eabi-gcc -c $CPU "$D/boot.S" -o "$OUT/boot.o"                                 || fail "boot.S did not assemble"

LG="$(arm-none-eabi-gcc $CPU -print-libgcc-file-name)"
arm-none-eabi-ld -T "$D/link.ld" -o "$OUT/f100gale.elf" \
    "$OUT/boot.o" "$OUT/gale.o" "$OUT/embed.o" "$OUT/hal.o" "$OUT/apply.o" "$OUT/tables.o" "$LG" \
  || fail "link failed"

left="$(arm-none-eabi-nm "$OUT/f100gale.elf" | awk '$1=="U"||$2=="U"{print $NF}' | sort -u)"
[ -z "$left" ] || fail "undefined after linking: $left"
nsym=$(arm-none-eabi-nm "$OUT/f100gale.elf" | wc -l | tr -d ' ')
[ "$nsym" -gt 0 ] || fail "no symbols in the linked image — the check above would be vacuous"
ram=$(arm-none-eabi-readelf -S "$OUT/f100gale.elf" | grep -E '\.data|\.bss')
[ -z "$ram" ] || fail "image has RAM sections nothing initialises: $ram"

if [ -n "${SYNTH_VERIFY:-}" ]; then
  command -v "$SYNTH_VERIFY" >/dev/null 2>&1 || [ -x "$SYNTH_VERIFY" ] \
    || fail "SYNTH_VERIFY='$SYNTH_VERIFY' is not an executable — 'could not run', not 'failed'"
  "$SYNTH_VERIFY" verify-embedder --allow-writer reset "$OUT/f100gale.elf" >"$OUT/ve.log" 2>&1 \
    || { cat "$OUT/ve.log"; fail "embedder ABI violated across gale-nano + harness"; }
  "$SYNTH_VERIFY" verify-embedder "$OUT/f100gale.elf" >/dev/null 2>&1 \
    && fail "verify-embedder ACCEPTED the image unacknowledged — it can no longer refuse"
  echo "embedder ABI: OK (writes confined to <reset>; refusal still works)"
elif [ -n "${REQUIRE_VERIFY:-}" ]; then
  fail "REQUIRE_VERIFY set but SYNTH_VERIFY is not"
else
  echo "embedder ABI: NOT CHECKED (set SYNTH_VERIFY to a synth >= 0.62)"
fi

arm-none-eabi-objcopy -O binary "$OUT/f100gale.elf" "$OUT/f100gale.bin" || fail "objcopy"
echo "built $OUT/f100gale.elf ($(wc -c <"$OUT/f100gale.bin") B raw, $nsym symbols)"
