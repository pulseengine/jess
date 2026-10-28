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
ELF="${ELF:-.scratch/invoke/ekf.elf}"
# The module defaults to the one the ELF was LOWERED FROM — build.sh writes both into the same
# directory. It used to default to the frozen repro/synth-1436/c.loom.wasm while the ELF default
# is rebuilt on the current pins, so a default run compared an ARM image of one module against
# wasmtime running ANOTHER (measured 2026-10-28: the two c.loom.wasm differ). The precondition
# need not catch that when the estimator's behaviour is unchanged between them. The frozen repro
# is still reachable: set MOD and an ELF lowered from it.
MOD="${MOD:-$(dirname "$ELF")/c.loom.wasm}"
# Absolute paths for both: QEMU is launched from $OUT, so a path relative to the repo would not
# resolve there. ELF used to be joined as "$ROOT/$ELF", which silently broke for an absolute ELF
# ("pmemsave produced nothing") — measured when this was first pointed at a build outside the repo.
case "$ELF" in /*) ;; *) ELF="$ROOT/$ELF";; esac
case "$MOD" in /*) ;; *) MOD="$ROOT/$MOD";; esac
TICKS="${TICKS:-16}"
IMU="${IMU:-0.0,0.0,-9.81,0.30,-0.15,0.07}"
LINBASE="${LINBASE:-0x20000000}"
LINSIZE="${LINSIZE:-0x10000}"
SETTLE="${SETTLE:-14}"
OUT="${OUT:-$ROOT/.scratch/linmem}"
# NOT hardcoded. It used to be, and AFD-141's bulk interface bump (0.10.0 -> 0.11.0, forced by a
# gate that compares literals against the PINNED falcon) broke this script: its DEFAULT module is
# the FROZEN repro/synth-1436/c.loom.wasm, which exports ekf@0.10.0. Measured: the 0.11.0 name
# raised KeyError there. The literal agreed with the pin and was wrong about what the script
# consumes. Now resolved from MOD itself, version-agnostically (ifacever.find_export, AFD-121).
EKF_EXPORT="${EKF_EXPORT:-}"
CHECK_ONLY=0; [ "${1:-}" = "--check-inputs" ] && { CHECK_ONLY=1; shift; }
PY="${PY:-python3}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
skip() { printf 'SKIP: %s\n' "$*" >&2; exit 2; }

# PREFLIGHT, naming every gap at once rather than one per run.
miss=""
"$PY" -c 'import wasmtime' 2>/dev/null || miss="$miss python-wasmtime"
[ -f "$MOD" ] || miss="$miss module($MOD)"
if [ "$CHECK_ONLY" = 0 ]; then
  command -v qemu-system-arm >/dev/null 2>&1 || miss="$miss qemu-system-arm"
  [ -f "$ELF" ] || miss="$miss image($ELF)"
fi
[ -n "$miss" ] && skip "missing:$miss — this is 'could not run', not 'the memories agree'"

mkdir -p "$OUT"
A="$OUT/arm-linmem.bin"
W="$OUT/wasmtime-linmem.bin"

# --check-inputs skips this whole side: it exists so CI can prove the export resolves and the
# derived offset reads a unit quaternion WITHOUT QEMU. (Measured: it first ran QEMU anyway.)
if [ "$CHECK_ONLY" = 0 ]; then
  echo "== ARM side: $ELF on QEMU mps2-an500, $TICKS ticks, then dump $LINSIZE at $LINBASE =="
  # pmemsave is given a RELATIVE path and qemu is run with cwd=$OUT, because the monitor's
  # readline mangles a long absolute path — measured: the file was silently never written and the
  # monitor reported "No such file or directory" for a directory that existed.
  rm -f "$A"
  ( cd "$OUT" && { sleep "$SETTLE"; echo "stop";
                   echo "pmemsave $LINBASE $LINSIZE arm-linmem.bin"; sleep 4; echo "quit"; } \
    | qemu-system-arm -machine mps2-an500 -cpu cortex-m7 -display none -serial none \
        -monitor stdio -kernel "$ELF" >/dev/null 2>&1 )
  [ -s "$A" ] || fail "pmemsave produced nothing — the ARM memory was never captured, so there is
     no comparison to report. (Check the monitor by hand; a long output path is known to break it.)"
  echo "   $(wc -c < "$A") bytes"
fi

echo "== wasmtime side: the same module, the same $TICKS ticks, the same IMU =="
RET="$OUT/return-area.hex"
"$PY" - "$MOD" "$TICKS" "$IMU" "$W" "$EKF_EXPORT" "$LINSIZE" "$RET" "$ROOT/tools/cascade-differential" <<'PYEOF' || fail "wasmtime side failed"
import sys
mod, ticks, imu, out, export, linsize, retf, here = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6], 16), sys.argv[7], sys.argv[8]
sys.path.insert(0, here)
from ifacever import find_export
from wasmtime import Store, Module, Instance
store = Store()
inst = Instance(store, Module.from_file(store.engine, mod), [])
ex = inst.exports(store)
export = export or find_export(list(ex._extern_map), "ekf#estimate")
print(f"   export {export}")
mem = ex["memory"]
have = mem.size(store) * 65536
if have < linsize:
    sys.exit(f"wasmtime linear memory is {have} B, less than the {linsize} B window — "
             "the comparison would read past it")
args = [float(x) for x in imu.split(",")]
ret = None
for _ in range(ticks):
    ret = ex[export](store, *args)
# The canonical ABI returns the 14-field vehicle-state through a pointer: the export's i32 result
# IS the return-area address. Taken from the module's own behaviour, so it tracks any layout
# change — measured 0xb024 on the meld 0.62 layout and 0xb064 on meld 0.64+ (+64, the guard).
if not isinstance(ret, int) or ret <= 0 or ret + 56 > linsize:
    sys.exit(f"the export returned {ret!r}, not a return-area pointer inside the {linsize} B window")
open(retf, "w").write(f"{ret:x}\n")
open(out, "wb").write(bytes(mem.read(store, 0, linsize)))
print(f"   {linsize} bytes; return area at 0x{ret:x} (from the export's own result)")
PYEOF

# ── THE PRECONDITION THAT MAKES THE OFFSETS COMPARABLE ───────────────────────────────────────
# Read the quaternion — the first 4 fields of the returned vehicle-state — at the return area the
# export itself reported, in both dumps. Two requirements, and the second is what makes it a check:
#   1. the four f32 words are BIT-IDENTICAL in both dumps (the offsets correspond), and
#   2. they form a UNIT QUATERNION. This is the positive control. The old form compared both dumps
#      at a FIXED 0xac18; both dumps come from the same module, so a meld layout shift moves them
#      TOGETHER and the comparison kept passing while no longer reading the quaternion — vacuous,
#      not red. Any shared content (zeros included) satisfied it. |q| = 1 does not.
qcheck() {   # qcheck <dump> [<dump2>] — exit 0 iff a unit quaternion, identical in every dump given
  "$PY" - "$RET" "$@" <<'PYEOF'
import struct, sys, math
off = int(open(sys.argv[1]).read().strip(), 16)
qs = []
for path in sys.argv[2:]:
    q = struct.unpack_from('<4f', open(path, 'rb').read(), off)
    w = struct.unpack_from('<4I', open(path, 'rb').read(), off)
    print(f"   {path.split('/')[-1]:<22} @0x{off:x}  " + ' '.join(f'{x:08x}' for x in w) + f"   |q|={math.sqrt(sum(x*x for x in q)):.9f}")
    qs.append(w)
n = math.sqrt(sum(x*x for x in struct.unpack_from('<4f', open(sys.argv[2], 'rb').read(), off)))
if abs(n - 1.0) > 1e-3:
    sys.exit(f"   NOT a unit quaternion (|q|={n:.6f}) at 0x{off:x} — the derived offset does not point at "
             "the vehicle-state, so nothing below would mean anything. Refusing.")
if len(set(qs)) != 1:
    sys.exit("   the quaternion DIFFERS between the dumps — either the layouts no longer correspond, or "
             "the attitude itself has started diverging, which is a DIFFERENT and larger finding than "
             "AFD-134 and must be investigated before this diff means anything.")
print("   unit quaternion" + (", bit-identical in both dumps -> the offsets correspond" if len(qs) > 1 else " -> the derived offset reads the vehicle-state"))
PYEOF
}

if [ "$CHECK_ONLY" = 1 ]; then
  echo "== --check-inputs: export resolved, return area derived, positive control (no QEMU) =="
  qcheck "$W" || fail "input check failed"
  echo "CHECK-INPUTS OK"
  exit 0
fi

echo "== precondition: a unit quaternion, bit-identical in both dumps, at the derived return area =="
qcheck "$A" "$W" || fail "offset-alignment precondition failed — refusing to report a diff
   of two memories that may not correspond offset-for-offset"

echo "== differential =="
# --return-area is the one the export reported (was hardcoded b024 — right only on the meld 0.62
# layout; 0xb064 on meld 0.64+). RETURN_AREA_OFF still overrides.
exec "$PY" tools/cascade-differential/linmem-differential.py "$A" "$W" \
     --return-area "${RETURN_AREA_OFF:-$(cat "$RET")}" "$@"
