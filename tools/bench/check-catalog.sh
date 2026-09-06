#!/usr/bin/env bash
# The catalogue is only worth having if it cannot silently disagree with the registry.
#
# TWO ASSERTIONS, both mechanical:
#   1. every device name a registry uses resolves to a catalogue entry. A name disagreement is
#      what makes a bench lock VACUOUS — gale independently chose `stlink-v1-f100` where the
#      registry said `stlink-v1`, and under the old prototype those were two different lock files
#      with neither excluding the other (AFD-082). The catalogue is the shared vocabulary; a
#      registry naming something it does not contain is that failure returning.
#   2. every `measured-by` artifact ID exists. A provenance claim pointing at nothing is worse
#      than no claim: it reads as evidence and is not.
#
# Negative-controlled in --self-test: both assertions must be shown to FAIL on injected input.
# A check nobody has watched fail is a check nobody has checked.
set -uo pipefail
cd "$(dirname "$0")/../.."
CAT=tools/bench/hardware-catalog.yaml
REG=${REG:-tools/bench/devices.yaml}

# PREFLIGHT. Name EVERY missing dependency at once, before doing any work — the pattern the
# on-target CI jobs already use. Discovering them one at a time costs a run per gap and names
# only one of them; and a bare `ModuleNotFoundError: yaml` traceback reads like a bug in this
# script rather than a missing package on the runner.
preflight() {
  local missing=""
  command -v python3 >/dev/null 2>&1 || missing="$missing python3"
  python3 -c 'import yaml' 2>/dev/null || missing="$missing python3-yaml(PyYAML)"
  command -v rivet   >/dev/null 2>&1 || missing="$missing rivet"
  if [ -n "$missing" ]; then
    echo "  PREFLIGHT FAIL — missing:$missing"
    echo "    This check needs python3 + PyYAML to read the catalogue, and rivet to confirm"
    echo "    every measured-by citation names a real artifact. Refusing to report a pass on"
    echo "    claims it could not check."
    return 1
  fi
  return 0
}

run_check() {
  local cat="$1" reg="$2"
  python3 - "$cat" "$reg" <<'PY'
import sys, yaml, subprocess
cat_p, reg_p = sys.argv[1], sys.argv[2]
cat = yaml.safe_load(open(cat_p))
names = set(cat.get('parts') or {}) | set(cat.get('boards') or {}) | set(cat.get('synthetic') or {})
reg = yaml.safe_load(open(reg_p)) or {}
used = set((reg.get('devices') or {}).keys())
fail = 0

missing = sorted(used - names)
if missing:
    print(f"  UNKNOWN TO THE CATALOGUE: {missing}")
    print( "    A registry naming a device the catalogue does not contain is the vacuous-lock")
    print( "    failure returning: two agents can then name the same hardware differently.")
    fail = 1
else:
    print(f"  names: {len(used)}/{len(used)} registry devices resolve in the catalogue")

cited = set()
for sect in ('parts', 'boards'):
    for e in (cat.get(sect) or {}).values():
        cited.update(e.get('measured-by') or [])
if cited:
    # FAIL CLOSED, and with a NAMED reason rather than a traceback. The first version put
    # subprocess.run OUTSIDE the try, so a missing `rivet` raised FileNotFoundError and the
    # script died with a stack trace instead of the refusal it was designed to print — the
    # operator then has to read Python internals to learn that a tool was absent. "Cannot
    # verify" is a verdict this check is allowed to reach; crashing is not.
    try:
        import json
        out = subprocess.run(['rivet', 'list', '--format', 'json'],
                             capture_output=True, text=True).stdout
        d = json.loads(out); arts = d if isinstance(d, list) else d.get('artifacts', d)
        have = {a['id'] for a in arts}
        dangling = sorted(cited - have)
        if dangling:
            print(f"  DANGLING PROVENANCE: {dangling} — cited as measuring a fact, does not exist")
            fail = 1
        else:
            print(f"  provenance: {len(cited)} cited artifacts all exist")
    except FileNotFoundError:
        print("  provenance: CANNOT VERIFY — `rivet` is not on PATH.")
        print("    This check needs it to confirm every measured-by citation names a real")
        print("    artifact. Refusing to report a pass on a claim it could not check.")
        fail = 1
    except Exception as e:
        print(f"  provenance: CANNOT VERIFY ({type(e).__name__}) — refusing to report a pass")
        fail = 1
sys.exit(fail)
PY
}

preflight || { echo "CATALOG FAIL"; exit 1; }

if [ "${1:-}" = "--self-test" ]; then
  echo "== negative controls: both assertions must be observed to FAIL =="
  t=$(mktemp -d)
  sed 's/^  pixhawk-6xrt:/  pixhawk-6xrt-typo:/' "$REG" > "$t/reg.yaml"
  if run_check "$CAT" "$t/reg.yaml" >/dev/null 2>&1; then
    echo "  NC1 FAILED: an unknown registry name did not trip the check"; rm -rf "$t"; exit 1
  fi
  echo "  NC1 ok: an unknown registry name is refused"
  sed 's/AFD-091/AFD-99999/' "$CAT" > "$t/cat.yaml"
  if run_check "$t/cat.yaml" "$REG" >/dev/null 2>&1; then
    echo "  NC2 FAILED: a dangling provenance citation did not trip the check"; rm -rf "$t"; exit 1
  fi
  echo "  NC2 ok: a citation to a non-existent artifact is refused"
  rm -rf "$t"
  echo "== the real thing =="
fi

run_check "$CAT" "$REG"
rc=$?
[ "$rc" -eq 0 ] && echo "CATALOG OK — registry names resolve, provenance exists." \
                || echo "CATALOG FAIL"
exit $rc
