#!/usr/bin/env bash
# Every `.scratch/<dir>/<file>` a script names must be a KEY in artifacts.pins.
#
# WHY (AFD-124). Renaming a pin path from `galenano7/gale-nano-0.7.0.wasm` to
# `galenano/gale-nano.wasm` left three consumers pointing at the old path:
# tools/flight-loop/run.sh, tools/timer-probe/run.sh and a ci.yml step. Two of them PASSED
# LOCALLY because the stale 0.7.0 artifact was still sitting in .scratch — so the bump was
# reported green against the artifact it was supposed to be replacing. That is AFD-047 exactly:
# a stale artifact jess's OWN script selected, which AFD-049 had to retract.
#
# The pins file is the single source of truth for what jess consumes. A script naming a path
# that is not a pin key is either consuming something unpinned or consuming a path nothing
# fetches; both are the same defect wearing different clothes. Reading BOTH sides — the scripts
# and the pins — is the AFD-120 shape: there is no third copy to drift.
#
# Negative-controlled in --self-test.
set -uo pipefail
cd "$(dirname "$0")/../.."
PINS="${PINS:-tools/deps/artifacts.pins}"

run_check() {
  local pins="$1" root="${2:-.}"
  python3 - "$pins" "$root" <<'PY'
import re, sys, os
pins_p, root = sys.argv[1], sys.argv[2]

# Directories the PINS own, taken from the pin keys themselves.
pin_dirs = set()
for line in open(pins_p):
    line = line.split('#')[0].strip()
    if not line or line.startswith('['):
        continue
    parts = line.split()
    if len(parts) >= 2 and len(parts[1]) == 64 and '/' in parts[0]:
        pin_dirs.add(parts[0].split('/', 1)[0])

# Directories scripts BUILD INTO. Declared here on purpose: the point of this gate is that
# every .scratch directory is accounted for as one or the other, so a directory belonging to
# NEITHER is the defect. Adding one is a deliberate, reviewable line.
DERIVED = {
    'invoke', 'appcompose', 'f100gale', 'f100hal', 'f100init', 'dispatch', 'timerprobe',
    'flightloop', 'xruntime', 'scry', 'renode', 'abi', 'einit', 'kiln', 'sil', 'soak',
}

# WHAT THIS CAN AND CANNOT DECIDE, stated so nobody reads more into a green than is there:
#   CATCHES  a reference into a .scratch directory that is neither pin-owned nor declared
#            derived — which is exactly what renaming a pin PATH leaves behind (AFD-124 left
#            three consumers on `galenano7/`, a directory that had ceased to exist).
#   MISSES   a renamed FILE inside a directory that is kept. Pin-owned directories also hold
#            build outputs (.scratch/falcon/ holds both the pinned components and casc_new.*),
#            so filenames cannot be checked at directory granularity without false positives.
#            A permanently-red gate is worse than no gate, so this one is deliberately narrower
#            than the whole hazard rather than noisy.
REF = re.compile(r'\.scratch/([A-Za-z0-9_.-]+)/[A-Za-z0-9_.+-]+\.(?:wasm|bin|o|elf)')
SCAN = ('tools', 'hardware', 'app', '.github')
SKIP_SELF = 'check-consumers.sh'
bad, seen = [], 0
for base in SCAN:
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, base)):
        dirnames[:] = [d for d in dirnames if d not in ('.git','target','node_modules','__pycache__')]
        for fn in filenames:
            if not fn.endswith(('.sh', '.yml', '.yaml', '.py')) or fn == SKIP_SELF:
                continue
            p = os.path.join(dirpath, fn)
            try:
                text = open(p, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            for d in set(REF.findall(text)):
                seen += 1
                if d not in pin_dirs and d not in DERIVED:
                    bad.append((os.path.relpath(p, root), d))
if not seen:
    print("  REFUSING: found NO .scratch artifact references at all — this check would be vacuous")
    sys.exit(2)
if bad:
    print(f"  ORPHANED .scratch DIRECTORY ({len(bad)} reference(s)):")
    for p, d in sorted(set(bad)):
        print(f"    {p}  ->  .scratch/{d}/")
    print( "    That directory is neither pin-owned nor a declared build output. A consumer left")
    print( "    on a renamed pin path PASSES against whatever stale artifact is still sitting")
    print( "    there — which is how a supplier bump gets reported green against the old bytes.")
    sys.exit(1)
print(f"  consumers: {seen} .scratch reference(s); every directory is pin-owned or declared derived")
print(f"             pin-owned: {sorted(pin_dirs)}")
PY
}

if [ "${1:-}" = "--self-test" ]; then
  echo "== negative control: a consumer on a non-pin path must FAIL =="
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  mkdir -p "$t/tools/fake"
  cp "$PINS" "$t/pins"
  printf 'NANO="$ROOT/.scratch/galenano7/gale-nano-0.7.0.wasm"\n' > "$t/tools/fake/run.sh"
  if run_check "$t/pins" "$t" >/dev/null 2>&1; then
    echo "  NC1 FAILED: a stale pin path was not caught"; exit 1
  fi
  echo "  NC1 ok: a consumer naming a non-pin path is refused"
  # NC2: the check must refuse to pass when it found nothing to check. A gate that reports
  # success over an empty scan is the vacuous-green this repo keeps finding in its own checkers.
  t2=$(mktemp -d); mkdir -p "$t2/tools"
  printf 'echo nothing here\n' > "$t2/tools/x.sh"
  run_check "$t/pins" "$t2" >/dev/null 2>&1; rc=$?
  rm -rf "$t2"
  if [ "$rc" -eq 0 ]; then echo "  NC2 FAILED: reported success having checked nothing"; exit 1; fi
  echo "  NC2 ok: finding no references at all is a refusal, not a pass"
  echo "== the real thing =="
fi

run_check "$PINS" "."
rc=$?
[ "$rc" -eq 0 ] && echo "CONSUMERS OK — every .scratch directory a script names is pin-owned or declared derived." \
                || echo "CONSUMERS FAIL"
exit $rc
