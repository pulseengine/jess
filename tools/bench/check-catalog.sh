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
    out = subprocess.run(['rivet', 'list', '--format', 'json'], capture_output=True, text=True).stdout
    try:
        import json
        d = json.loads(out); arts = d if isinstance(d, list) else d.get('artifacts', d)
        have = {a['id'] for a in arts}
        dangling = sorted(cited - have)
        if dangling:
            print(f"  DANGLING PROVENANCE: {dangling} — cited as measuring a fact, does not exist")
            fail = 1
        else:
            print(f"  provenance: {len(cited)} cited artifacts all exist")
    except Exception as e:
        print(f"  provenance: CANNOT VERIFY ({type(e).__name__}) — refusing to report a pass")
        fail = 1
sys.exit(fail)
PY
}

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
