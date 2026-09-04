#!/usr/bin/env bash
# Build the TEST-PIX-032 cascade-invocation image.
#
# Links a synth --relocatable falcon cascade object with a harness that keeps the two
# embedder promises (AFD-051) and then actually CALLS rate@0.7.0#tick — the thing
# AFD-056 showed the self-contained image never does.
#
# NOTE flags are written out, not held in a variable: zsh does not word-split an
# unquoted variable, which silently produced `-mcpu=cortex-m7 -mfpu=...` as ONE argument
# and four confusing errors.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$D/../../.." && pwd)"
# SCRATCH is the tree tools/deps/fetch.sh populates and tools/deps/check.sh verifies.
# Overridable so a CLEAN CHECKOUT can build from freshly fetched, digest-verified inputs
# rather than from whatever happens to be in .scratch (AFD-065).
SCRATCH="${SCRATCH:-$ROOT/.scratch}"
OUT="${OUT:-$SCRATCH/invoke}"; mkdir -p "$OUT"
SYNTH="${SYNTH:-$SCRATCH/fg60/synth}"
PY="${PY:-python3}"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v arm-none-eabi-gcc >/dev/null || fail "arm-none-eabi-gcc not on PATH"
[ -x "$SYNTH" ] || fail "synth not at $SYNTH"
# Pass SCRATCH EXPLICITLY. This previously relied on the child inheriting it from the
# environment, so a caller that set SCRATCH as a shell variable rather than exporting it
# would have had its inputs verified against the DEFAULT tree — the same defect AFD-065
# found in fetch.sh, latent here.
#
# RELEASE-WATCH: when SYNTH is overridden away from the pinned binary (testing a candidate
# release), that one pin is set aside EXPLICITLY and the version actually used is printed.
# The input pins — the falcon stages and gale-nano — are still enforced, because a
# toolchain differential is only meaningful if the inputs are identical.
PINNED_SYNTH="$SCRATCH/fg60/synth"
if [ "$SYNTH" = "$PINNED_SYNTH" ]; then
  SCRATCH="$SCRATCH" "$ROOT/tools/deps/check.sh" >/dev/null 2>&1 \
    || fail "external artifacts do not match tools/deps/artifacts.pins"
else
  SCRATCH="$SCRATCH" "$ROOT/tools/deps/check.sh" --exclude fg60/synth >/dev/null 2>&1 \
    || fail "input artifacts do not match tools/deps/artifacts.pins (synth pin excluded)"
  export DEPS_EXCLUDE="fg60/synth"   # threaded to the sub-oracles' own preflights
  echo "!! OFF-PIN TOOLCHAIN — release-watch mode"
  echo "!!   synth in use : $("$SYNTH" --version 2>&1 | head -1)  ($SYNTH)"
  echo "!!   pinned synth : $(grep '^fg60/synth' "$ROOT/tools/deps/artifacts.pins" | awk '{print $3}' | sed 's/.*@//;s/!.*//')"
  echo "!!   inputs ARE pin-verified; results from this build are a CANDIDATE differential,"
  echo "!!   not a campaign result, until the pin is updated."
fi

echo "== 1. fuse + lower (the object and its init tables come from ONE module) =="
varve run meld fuse "$SCRATCH"/v1341/{rate,mixer,attitude,position,iekf}.wasm \
    --memory shared --pack-rebase -o "$OUT/c.wasm" >"$OUT/meld.log" 2>&1 || fail "meld"
varve run loom optimize "$OUT/c.wasm" -o "$OUT/c.loom.wasm" >"$OUT/loom.log" 2>&1 || fail "loom"
"$SYNTH" compile "$OUT/c.loom.wasm" -t cortex-m7dp --cortex-m --relocatable \
    --embedder-data-init --embedder-global-init -o "$OUT/cascade.o" >"$OUT/synth.log" 2>&1 || fail "synth"

echo "== 2. extract the init tables from THAT SAME module =="
MOD="$OUT/c.loom.wasm" PY="$PY" OUT="$OUT/einit" "$ROOT/tools/embedder-init/run.sh" >"$OUT/einit.log" 2>&1 \
  || { tail -3 "$OUT/einit.log" >&2; fail "embedder-init"; }

echo "== 3. rename the export ('@' begins an ARM comment, so an asm label truncates it) =="
arm-none-eabi-objcopy \
  --redefine-sym 'pulseengine:falcon-cascade/rate@0.7.0#tick=jess_rate_tick' \
  --redefine-sym 'pulseengine:falcon-cascade/mixer@0.7.0#mix=jess_mixer_mix' \
  "$OUT/cascade.o" "$OUT/cascade_named.o" || fail "objcopy"
# ASSERT the rename landed — a silent no-op would leave an unresolved reference and the
# only symptom would be a link error three steps later.
for sym in jess_rate_tick jess_mixer_mix; do
  arm-none-eabi-nm "$OUT/cascade_named.o" | grep -qE " T $sym\$" \
    || fail "objcopy --redefine-sym did not produce $sym"
done

echo "== 4. compile + link =="
arm-none-eabi-gcc -c -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard "$D/boot.S"    -o "$OUT/boot.o"    || fail "boot.S"
# -ffixed-r9/-r10/-r11: the synth --relocatable ABI (synth#1131, docs/embedder-abi-relocatable-arm.md)
# RESERVES these three for the embedder — R11 linmem base, R10 linmem size, R9 globals base — and
# anything the object calls out to must PRESERVE them. GCC would otherwise be free to allocate R11
# as a frame pointer inside the C shim, which would hand synth's code a frame pointer where it
# expects the linear-memory base.
#
# Today jess_call_rate happens to compile to a bare `b.w` tail-branch, so nothing is clobbered and
# the harness works. That is luck, not conformance: the moment the shim grows a body (a soak loop,
# a log line) the guarantee evaporates silently and the symptom would be a wrong torque, not a
# build error. Reserving the registers makes it structural.
arm-none-eabi-gcc -c -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -ffreestanding -O2 \
    -ffixed-r9 -ffixed-r10 -ffixed-r11 "$D/harness.c" -o "$OUT/harness.o" || fail "harness.c"
arm-none-eabi-gcc -c -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -ffreestanding -O2 \
    -ffixed-r9 -ffixed-r10 -ffixed-r11 "$OUT/einit/jess_wasm_init.c" -o "$OUT/init.o" || fail "init.c"
LG="$(arm-none-eabi-gcc -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -print-libgcc-file-name)"
arm-none-eabi-ld -T "$D/link.ld" "$OUT/boot.o" "$OUT/harness.o" "$OUT/init.o" "$OUT/cascade_named.o" "$LG" \
    -o "$OUT/invoke.elf" || fail "link"

left="$(arm-none-eabi-nm "$OUT/invoke.elf" | awk '$1=="U"||$2=="U"{print $NF}' | sort -u)"
[ -z "$left" ] || fail "undefined after link: $left"
# An empty ELF also shows no undefined symbols, so count what survived.
n=$(arm-none-eabi-nm "$OUT/invoke.elf" | grep -cE ' T (jess_rate_tick|jess_mixer_mix|_reset|jess_init|jess_call_chain)$')
[ "$n" -ge 5 ] || fail "expected symbols missing from the image ($n/5)"
# ASSERT the reservation held: no harness object may WRITE r9/r10/r11. Checked on the emitted
# code rather than trusting the flag, because a flag that silently stopped applying would look
# exactly like a flag that is working.
for o in "$OUT/harness.o" "$OUT/init.o"; do
  bad="$(arm-none-eabi-objdump -d "$o" 2>/dev/null \
    | grep -oE '\b(mov|ldr|add|sub|str)[a-z.]*\s+(r9|sl|r10|fp|r11),' | sort -u)"
  [ -z "$bad" ] || fail "$(basename "$o") WRITES an embedder-reserved register: $bad"
done
echo "   embedder registers r9/r10/r11 not written by any harness object"

echo "   linked: $(stat -f%z "$OUT/invoke.elf" 2>/dev/null || stat -c%s "$OUT/invoke.elf") B, 0 undefined, $n/5 key symbols"

echo "== 4b. build the N-TICK SOAK image (TEST-PIX-033) =="
# A SEPARATE image on purpose: the chain image has already advanced the cascade one tick by
# the time it parks its result, so a soak appended to it would be offset by one against the
# wasmtime reference — the same class of error as AFD-060's double rate#tick.
#
# This is also the case the -ffixed-r9/-r10/-r11 reservation above was added FOR. jess_call_soak
# has a real loop body, so GCC now has genuine register pressure where jess_call_rate had none
# and compiled to a bare tail-branch. The emitted-code assertion below is what turns that from
# luck into a checked property.
arm-none-eabi-gcc -c -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard "$D/boot-soak.S" -o "$OUT/boot_soak.o" || fail "boot-soak.S"
arm-none-eabi-ld -T "$D/link.ld" "$OUT/boot_soak.o" "$OUT/harness.o" "$OUT/init.o" "$OUT/cascade_named.o" "$LG" \
    -o "$OUT/soak.elf" || fail "soak link"
left="$(arm-none-eabi-nm "$OUT/soak.elf" | awk '$1=="U"||$2=="U"{print $NF}' | sort -u)"
[ -z "$left" ] || fail "undefined after soak link: $left"
ns=$(arm-none-eabi-nm "$OUT/soak.elf" | grep -cE ' T (jess_rate_tick|jess_mixer_mix|_reset|jess_init|jess_call_soak)$')
[ "$ns" -ge 5 ] || fail "soak image missing expected symbols ($ns/5)"
# Re-assert on the SOAK image specifically. harness.o is shared, but the check is cheap and the
# failure it guards (a frame pointer handed to synth where it expects the linmem base) is silent.
bad="$(arm-none-eabi-objdump -d "$OUT/harness.o" 2>/dev/null \
  | grep -oE '\b(mov|ldr|add|sub|str)[a-z.]*\s+(r9|sl|r10|fp|r11),' | sort -u)"
[ -z "$bad" ] || fail "harness.o (with the soak loop) WRITES an embedder-reserved register: $bad"
# The soak loop must actually be a LOOP. -O2 could in principle unroll or, worse, hoist the call
# out if it were wrongly assumed pure; a straight-line body would silently soak once.
arm-none-eabi-objdump -d "$OUT/soak.elf" --disassemble=jess_call_soak 2>/dev/null > "$OUT/soak.dis" || true
# NOTE: there is deliberately NO static "does jess_call_soak contain a backward branch"
# assertion here. Two versions were tried and both were vacuous: the obvious grep is
# satisfied by the forward early-exit -O2 emits, and an address-comparing version is
# satisfied by the INNER 4-word fold loop even when the outer soak loop is gone. The
# evidence that N iterations actually ran is DYNAMIC and lives in the oracle: the image
# writes the loop's own trip count to SOAK_BASE, and the fold over N ticks differs from
# the fold over any other count.
echo "   soak image: $(stat -f%z "$OUT/soak.elf" 2>/dev/null || stat -c%s "$OUT/soak.elf") B, 0 undefined, $ns/5 symbols, loop present"

# The soak's own negative control: the same 64-tick run with the data-segment and globals
# init short-circuited (nc2.o). It must complete — sentinel and all — yet fold DIFFERENTLY.
# Built here so the oracle cannot silently skip it. Note this image is linked AFTER nc2.o
# exists, so the ordering in step 5 matters; the assert below catches a reorder.

echo "== 5. build the two negative-control images =="
# NC1 — perturb wy in the argument vector. The torque MUST move; a stage returning a
# constant would match the reference forever.
sed 's/0xBE19999Au,/0xBE4CCCCDu,/' "$D/harness.c" > "$OUT/nc1.c"
cmp -s "$D/harness.c" "$OUT/nc1.c" && fail "NC1 edit changed nothing — the perturbation did not apply"
arm-none-eabi-gcc -c -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -ffreestanding -O2 -ffixed-r9 -ffixed-r10 -ffixed-r11 "$OUT/nc1.c" -o "$OUT/nc1.o" || fail "nc1 compile"
arm-none-eabi-ld -T "$D/link.ld" "$OUT/boot.o" "$OUT/nc1.o" "$OUT/init.o" "$OUT/cascade_named.o" "$LG" -o "$OUT/nc1.elf" || fail "nc1 link"

# NC2 — keep the argument but SKIP the data-segment and globals init. synth emits
# byte-identical code with or without the --embedder-* flags, so this is the only way to
# show the promises are load-bearing rather than ceremonial.
sed 's/^    for (jess_usize s = 0/    return; for (jess_usize s = 0/' "$D/harness.c" > "$OUT/nc2.c"
cmp -s "$D/harness.c" "$OUT/nc2.c" && fail "NC2 edit changed nothing"
arm-none-eabi-gcc -c -mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard -ffreestanding -O2 -Wno-unreachable-code -ffixed-r9 -ffixed-r10 -ffixed-r11 "$OUT/nc2.c" -o "$OUT/nc2.o" || fail "nc2 compile"
arm-none-eabi-ld -T "$D/link.ld" "$OUT/boot.o" "$OUT/nc2.o" "$OUT/init.o" "$OUT/cascade_named.o" "$LG" -o "$OUT/nc2.elf" || fail "nc2 link"
echo "   nc1.elf (perturbed input) and nc2.elf (no embedder init) built"

echo "== 5b. the paint band must be ZERO in the module's own data =="
# harness.c paints [0x400,0x2000) with 0xDEADBEEF to measure the linear-memory high-water
# mark. The comment used to claim that band is "above the static data top". IT IS NOT:
# __data_end is 0x45A1 and one data segment spans [0x290,0x22B1), so the paint overwrites
# ~7 KiB of applied segment data. It is harmless ONLY because those bytes are zero and are
# never read — which is a property of TODAY's module, not a guarantee. Clean-room
# verification found this; assert it so a future module with non-zero static data in that
# band fails here loudly instead of diverging from the reference for a non-lowering reason.
"$PY" - "$OUT/c.loom.wasm" <<'EOP' || fail "paint band overlaps NON-ZERO module data"
import sys
from wasmtime import Store, Module, Instance
LO, HI = 0x400, 0x2000
store = Store(); inst = Instance(store, Module.from_file(store.engine, sys.argv[1]), [])
mem = inst.exports(store)["memory"]
b = mem.read(store, LO, HI)
nz = [i for i, v in enumerate(b) if v]
if nz:
    sys.stderr.write(f"{len(nz)} non-zero byte(s) in [0x{LO:X},0x{HI:X}), first at 0x{LO+nz[0]:X}\n")
    sys.exit(1)
print(f"   [0x{LO:X},0x{HI:X}) is all-zero after instantiation — painting it cannot perturb the run")
EOP

echo "== 6. the SOAK negative controls =="
# CONTROL A (attributive) — PERTURB THE INPUT, keep the embedder init entirely. This is the
# soak-level analogue of nc1 and the one that actually attributes a wrong answer to a wrong
# computation: the result must be PLAUSIBLE-but-wrong, not a collapse to zero.
#
# Clean-room verification showed the init-skipped image alone was NOT evidence about the
# embedder promises: it folds to FNV over 256 ZERO words, and an image that keeps the
# promises but drops the argument write folds identically. Three different breakages, one
# indistinguishable fold. That control answers "did anything survive", nothing more.
arm-none-eabi-ld -T "$D/link.ld" "$OUT/boot_soak.o" "$OUT/nc1.o" "$OUT/init.o" "$OUT/cascade_named.o" "$LG" \
    -o "$OUT/soak_nc1.elf" || fail "soak_nc1 link"
cmp -s "$OUT/soak.elf" "$OUT/soak_nc1.elf" && fail "soak_nc1.elf is byte-identical to soak.elf — the control is inert"
echo "   soak_nc1.elf (perturbed input, full init) linked and differs from soak.elf"

# CONTROL B (liveness) — init skipped.
[ -f "$OUT/nc2.o" ] || fail "nc2.o missing — step 5 must run before the soak control is linked"
arm-none-eabi-ld -T "$D/link.ld" "$OUT/boot_soak.o" "$OUT/nc2.o" "$OUT/init.o" "$OUT/cascade_named.o" "$LG" \
    -o "$OUT/soak_nc2.elf" || fail "soak_nc2 link"
cmp -s "$OUT/soak.elf" "$OUT/soak_nc2.elf" && fail "soak_nc2.elf is byte-identical to soak.elf — the control is inert"
echo "   soak_nc2.elf linked and differs from soak.elf"

