#!/usr/bin/env bash
# Capture BOTH linear memories — the synth-lowered ARM run and wasmtime — over the same module
# and the same tick count, then diff them with linmem-differential.py.
#
# ONE COMMAND, because a differential assembled by hand is a differential nobody else can
# reproduce, and synth#1436 is a conversation in which both sides need to re-run each other's
# measurements. Everything that could drift between the two sides is pinned here: the module,
# the tick count, the IMU vector and the offset base.
#
# WHY THE COMPARISON IS LEGITIMATE AT ALL — the one assumption, stated so it can be attacked:
# the fused module is built `--memory shared`, and the lowered image maps wasm linear memory at
# LINMEM = 0x20000000 with nothing else in the window. So wasm offset N is ARM address
# 0x20000000+N on one side and byte N of wasmtime's memory export on the other, and the same
# offset means the same thing. If that ever stops holding, this script must FAIL rather than
# produce a diff of two unrelated layouts — which is why it asserts the quaternion offset
# agreement as a precondition before reporting anything.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
MOD="${MOD:-repro/synth-1436/c.loom.wasm}"
ELF="${ELF:-.scratch/invoke/ekf.elf}"
TICKS="${TICKS:-16}"
IMU="${IMU:-0.0,0.0,-9.81,0.30,-0.15,0.07}"
LINBASE="${LINBASE:-0x20000000}"
LINSIZE="${LINSIZE:-0x10000}"
SETTLE="${SETTLE:-14}"
OUT="${OUT:-$ROOT/.scratch/linmem}"
EKF_EXPORT="pulseengine:falcon-cascade/ekf@0.10.0#estimate"
PY="${PY:-python3}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
skip() { printf 'SKIP: %s\n' "$*" >&2; exit 2; }

# PREFLIGHT, naming every gap at once rather than one per run.
miss=""
command -v qemu-system-arm >/dev/null 2>&1 || miss="$miss qemu-system-arm"
"$PY" -c 'import wasmtime' 2>/dev/null || miss="$miss python-wasmtime"
[ -f "$MOD" ] || miss="$miss module($MOD)"
[ -f "$ELF" ] || miss="$miss image($ELF)"
[ -n "$miss" ] && skip "missing:$miss — this is 'could not run', not 'the memories agree'"

mkdir -p "$OUT"
A="$OUT/arm-linmem.bin"
W="$OUT/wasmtime-linmem.bin"

echo "== ARM side: $ELF on QEMU mps2-an500, $TICKS ticks, then dump $LINSIZE at $LINBASE =="
# pmemsave is given a RELATIVE path and qemu is run with cwd=$OUT, because the monitor's
# readline mangles a long absolute path — measured: the file was silently never written and the
# monitor reported "No such file or directory" for a directory that existed.
rm -f "$A"
( cd "$OUT" && { sleep "$SETTLE"; echo "stop";
                 echo "pmemsave $LINBASE $LINSIZE arm-linmem.bin"; sleep 4; echo "quit"; } \
  | qemu-system-arm -machine mps2-an500 -cpu cortex-m7 -display none -serial none \
      -monitor stdio -kernel "$ROOT/$ELF" >/dev/null 2>&1 )
[ -s "$A" ] || fail "pmemsave produced nothing — the ARM memory was never captured, so there is
   no comparison to report. (Check the monitor by hand; a long output path is known to break it.)"
echo "   $(wc -c < "$A") bytes"

echo "== wasmtime side: the same module, the same $TICKS ticks, the same IMU =="
"$PY" - "$MOD" "$TICKS" "$IMU" "$W" "$EKF_EXPORT" "$LINSIZE" <<'PYEOF' || fail "wasmtime side failed"
import sys
from wasmtime import Store, Module, Instance
mod, ticks, imu, out, export, linsize = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6], 16)
store = Store()
inst = Instance(store, Module.from_file(store.engine, mod), [])
ex = inst.exports(store)
mem = ex["memory"]
have = mem.size(store) * 65536
if have < linsize:
    sys.exit(f"wasmtime linear memory is {have} B, less than the {linsize} B window — "
             "the comparison would read past it")
args = [float(x) for x in imu.split(",")]
for _ in range(ticks):
    ex[export](store, *args)
open(out, "wb").write(bytes(mem.read(store, 0, linsize)))
print(f"   {linsize} bytes")
PYEOF

# ── THE PRECONDITION THAT MAKES THE OFFSETS COMPARABLE ───────────────────────────────────────
# The persistent quaternion is at offset 0xac18 and is bit-identical between the runtimes. That
# is a MEASURED fact (AFD-134), and it doubles as the alignment check: if the two dumps did not
# correspond offset-for-offset, four f32 words would not agree bit-for-bit by chance. If this
# ever fails, the layouts have diverged and every difference below would be an artefact of
# comparing unrelated addresses.
echo "== precondition: the persistent quaternion at 0xac18 must agree, or the offsets are not =="
"$PY" - "$A" "$W" <<'PYEOF' || fail "offset-alignment precondition failed — refusing to report a diff
   of two memories that may not correspond offset-for-offset"
import struct, sys
a = open(sys.argv[1], 'rb').read(); w = open(sys.argv[2], 'rb').read()
qa = struct.unpack_from('<4I', a, 0xac18); qw = struct.unpack_from('<4I', w, 0xac18)
sa = ' '.join(f'{x:08x}' for x in qa); sw = ' '.join(f'{x:08x}' for x in qw)
print(f"   arm      {sa}")
print(f"   wasmtime {sw}")
if qa != qw:
    sys.exit("   the quaternion DIFFERS — either the layouts no longer correspond, or the "
             "quaternion itself has started diverging, which is a DIFFERENT and larger finding "
             "than AFD-134 and must be investigated before this diff means anything.")
print("   identical -> the offsets correspond, and the attitude state itself agrees")
PYEOF

echo "== differential =="
# --return-area defaults to the ekf state struct's offset, measured: ARM 0x2000b024.
exec "$PY" tools/cascade-differential/linmem-differential.py "$A" "$W" \
     --return-area "${RETURN_AREA_OFF:-b024}" "$@"
