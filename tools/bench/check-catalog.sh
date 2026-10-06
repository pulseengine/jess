#!/usr/bin/env bash
# The catalogue is only worth having if it cannot silently disagree with the registry.
#
# THREE ASSERTIONS, all mechanical:
#   1. every device name a registry uses resolves to a catalogue entry. A name disagreement is
#      what makes a bench lock VACUOUS — gale independently chose `stlink-v1-f100` where the
#      registry said `stlink-v1`, and under the old prototype those were two different lock files
#      with neither excluding the other (AFD-082). The catalogue is the shared vocabulary; a
#      registry naming something it does not contain is that failure returning.
#   2. every `measured-by` artifact ID exists. A provenance claim pointing at nothing is worse
#      than no claim: it reads as evidence and is not.
#   3. every registry ALIAS resolves too, and no alias is ambiguous. Aliases exist so a device can
#      be RENAMED without the old and new names taking different flocks (jess#266) — which means
#      an alias is a name that can take a lock, and an unchecked one is assertion 1's hole
#      reopened under a different key. An alias colliding with another device's name, or claimed
#      by two devices, is refused rather than resolved: the lock would exclude the wrong agent.
#
# Negative-controlled in --self-test: every assertion must be shown to FAIL on injected input.
# A check nobody has watched fail is a check nobody has checked.
set -uo pipefail
cd "$(dirname "$0")/../.."
# Both overridable: an NC must be able to point at a modified COPY. CAT was not, and a
# control that set it silently tested the real catalogue and reported OK — a control that
# cannot perturb its subject is a control that proves nothing.
CAT=${CAT:-tools/bench/hardware-catalog.yaml}
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
# A device name may resolve to a BOARD, an ADAPTER or a SYNTHETIC entry — and NEVER to a PART.
# THE RULE WAS PROSE AND THEREFORE UNENFORCED. The naming rule at the head of `boards:` says
# "EVERY DEVICE NAME IS A BOARD, NEVER A PROBE MODEL", agreed with gale on jess#266 after an
# unpinned openocd reached the wrong board twice while a claim on another was held (gale#397).
# But this line used to union `parts` into the acceptable set, so a registry naming a PROBE MODEL
# passed the very gate that exists to enforce the rule. Measured 2026-10-02: three live
# violations, all of them in host-local registries — `stlink-v3` and `stlink-v1` on gale.local,
# `stlink-v3` on wohl.local. A probe-model name is ONE LOCK FOR EVERY BOARD CARRYING THAT MODEL,
# which is AFD-082's vacuous lock by construction rather than by typo.
# `parts` stays loadable so `boards[].parts` can still be cross-checked; it is just not a
# namespace a device may be named from.
lockable = set(cat.get('boards') or {}) | set(cat.get('standalone') or {}) | set(cat.get('synthetic') or {})
part_only = set(cat.get('parts') or {}) - lockable
names = lockable | part_only          # resolves at all (assertion 1)
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

# ASSERTION 1b — and they resolve to something LOCKABLE. See the note on `lockable` above.
# ASSERTION 1c — a `standalone:` entry MUST carry a serial. That section exists for a device
# that IS the claimable thing, and the ONLY thing separating it from a probe MODEL is that there
# is exactly one of it, identified by serial. Without a serial the entry re-opens 1b's hole in the
# section built to avoid it: `stlink-v2-1` would be perfectly legal as a `standalone:` name.
noserial = sorted(k for k, v in (cat.get('standalone') or {}).items() if not (v or {}).get('serial'))
if noserial:
    print(f"  STANDALONE ENTRY WITH NO SERIAL: {noserial}")
    print( "    `standalone:` is for one physical object, distinguished from a probe MODEL by its")
    print( "    serial. Without one the name cannot be shown to mean a single device, which is")
    print( "    exactly what assertion 1b refuses in the `parts:` section.")
    fail = 1

named_parts = sorted(used & part_only)
if named_parts:
    print(f"  A DEVICE IS NAMED AFTER A PART, NOT A BOARD: {named_parts}")
    print( "    The catalogue lists these under `parts:` — they are component MODELS. A probe")
    print( "    model is one lock for every board carrying it, so two boards on one host share")
    print( "    a single lock and the interlock does not exclude (gale#397, jess#266).")
    print( "    Rename the device after its BOARD and keep the old name as an `aliases:` entry,")
    print( "    so a claim already held under the old name still excludes.")
    fail = 1

# ASSERTION 3 — aliases. An alias is a name that takes a lock, so it needs every guarantee a
# device name needs. `with-device` refuses an ambiguous registry at run time; this refuses it in
# CI, before anyone is holding anything.
def alias_list(e):
    a = (e or {}).get('aliases') or []
    return [a] if isinstance(a, str) else list(a)

owner = {}
alias_fail = 0
for dev, e in (reg.get('devices') or {}).items():
    for a in alias_list(e):
        if a in used and a != dev:
            print(f"  AMBIGUOUS ALIAS: '{a}' is an alias of '{dev}' AND a device in its own right")
            alias_fail = 1
        elif a in owner and owner[a] != dev:
            print(f"  AMBIGUOUS ALIAS: '{a}' is claimed by both '{owner[a]}' and '{dev}'")
            alias_fail = 1
        owner[a] = dev
# An alias takes a lock, so it is held to 1b's SPIRIT — but not to its letter, and the
# difference is the whole point.
#
# WHAT 1b ACTUALLY PROTECTS AGAINST is ONE NAME REACHING TWO BOARDS. gale#397 happened because
# `stlink-v2-1` could mean either of the two boards on wohl.local carrying that probe. A name
# that reaches exactly ONE board on its host is not that hazard, whatever it is named after.
#
# A FLAT BAN WAS MY FIRST ATTEMPT AND IT WAS WRONG: it refused the backward-compatibility
# aliases created by this very gate's prescribed rename, and FIVE COMMITTED SCRIPTS pass
# `stlink-v1` as a device name (hardware/silicon/f100*/run-on-silicon.sh, negative-control.sh).
# So the flat rule made the gate demand a breaking change for no measurable safety gain. The
# test is AMBIGUITY, measured against the catalogue, not the shape of the name.
#
# Resolved per registry, because ambiguity is a property of ONE HOST's hardware: `stlink-v3` is
# unambiguous on gale.local (one V3 there) and would be ambiguous on a host carrying two.
cat_parts = {}
for sect in ('boards', 'standalone'):
    for k, v in (cat.get(sect) or {}).items():
        cat_parts[k] = set((v or {}).get('parts') or []) | ({k} if sect == 'standalone' else set())
for a in sorted(set(owner) & part_only):
    carriers = sorted(d for d in used if a in cat_parts.get(d, set()))
    if len(carriers) > 1:
        print(f"  AMBIGUOUS ALIAS (A PART CARRIED BY SEVERAL REGISTERED DEVICES): '{a}' -> {carriers}")
        print( "    This is exactly gale#397: one name an agent can type that reaches more than")
        print( "    one board on this host. Name the board instead.")
        alias_fail = 1
    elif not carriers:
        print(f"  ALIAS NAMES A PART NO REGISTERED DEVICE CARRIES: '{a}'")
        print( "    It would take a lock standing for nothing on this host.")
        alias_fail = 1
    elif carriers[0] != owner[a]:
        print(f"  MISLEADING ALIAS: '{a}' is an alias of '{owner[a]}', but the only registered")
        print(f"    device carrying that part is '{carriers[0]}'. The name would take one")
        print( "    board's lock while naming another's hardware.")
        alias_fail = 1
unknown_alias = sorted(set(owner) - names)
if unknown_alias:
    print(f"  ALIAS UNKNOWN TO THE CATALOGUE: {unknown_alias}")
    print( "    An alias is a name that can take a lock. One the catalogue does not contain is")
    print( "    the same vacuous-lock failure as assertion 1, under a different key.")
    alias_fail = 1
if alias_fail:
    fail = 1
elif owner:
    print(f"  aliases: {len(owner)} alias(es) resolve and are unambiguous")
else:
    print( "  aliases: none declared")

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
  echo "== negative controls: every assertion must be observed to FAIL =="
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

  # NC3/NC4 cover assertion 3. Injected into a COPY of the real registry, so they exercise the
  # same reader the real check uses rather than a hand-built fixture that could drift from it.
  python3 - "$REG" "$t/alias-unknown.yaml" "$t/alias-collide.yaml" <<'PYNC'
import sys, yaml
reg = yaml.safe_load(open(sys.argv[1]))
d = reg['devices']; first = sorted(d)[0]
a = yaml.safe_load(yaml.dump(reg)); a['devices'][first]['aliases'] = ['no-such-board']
yaml.safe_dump(a, open(sys.argv[2], 'w'))
b = yaml.safe_load(yaml.dump(reg))
other = [k for k in sorted(d) if k != first][0]
b['devices'][first]['aliases'] = [other]      # an alias that IS another device
yaml.safe_dump(b, open(sys.argv[3], 'w'))
PYNC
  if run_check "$CAT" "$t/alias-unknown.yaml" >/dev/null 2>&1; then
    echo "  NC3 FAILED: an alias the catalogue does not contain did not trip the check"
    rm -rf "$t"; exit 1
  fi
  echo "  NC3 ok: an alias unknown to the catalogue is refused"
  if run_check "$CAT" "$t/alias-collide.yaml" >/dev/null 2>&1; then
    echo "  NC4 FAILED: an alias colliding with a device name did not trip the check"
    rm -rf "$t"; exit 1
  fi
  echo "  NC4 ok: an alias that is also a device name is refused"

  # NC5/NC6 cover assertion 1b — the rule that was prose for a month (AFD-136). Both inject a
  # PART name (a probe model) built from the catalogue's own `parts:` section, so the control
  # cannot drift from the thing it controls.
  python3 - "$CAT" "$REG" "$t/dev-is-part.yaml" <<'PYNC2'
import sys, yaml
cat = yaml.safe_load(open(sys.argv[1])); reg = yaml.safe_load(open(sys.argv[2]))
lockable = set(cat.get('boards') or {}) | set(cat.get('standalone') or {}) | set(cat.get('synthetic') or {})
part_only = sorted(set(cat.get('parts') or {}) - lockable)
assert part_only, "the catalogue has no parts-only entry, so NC5/NC6 would be vacuous"
part = part_only[0]
d = sorted(reg['devices'])[0]
a = yaml.safe_load(yaml.dump(reg))
a['devices'][part] = a['devices'].pop(d)          # a DEVICE named after a probe model
yaml.safe_dump(a, open(sys.argv[3], 'w'))
print(f"  (NC5/NC6 use the part name '{part}')")
PYNC2
  if run_check "$CAT" "$t/dev-is-part.yaml" >/dev/null 2>&1; then
    echo "  NC5 FAILED: a device named after a PART (a probe model) did not trip the check"
    rm -rf "$t"; exit 1
  fi
  echo "  NC5 ok: a device named after a probe model is refused (jess#266, gale#397)"
  # NC6 group covers the SHARPENED alias rule: ambiguity, not shape. Fixtures are derived from
  # the real catalogue, so they cannot drift from the thing they control. The ambiguous case is
  # REAL — `stlink-v2-1` is carried by two catalogue boards, which is gale#397's actual shape.
  python3 - "$CAT" "$REG" "$t/alias-ambig.yaml" "$t/alias-one.yaml" "$t/alias-wrong.yaml" <<'PYNC4'
import sys, yaml
cat = yaml.safe_load(open(sys.argv[1])); reg = yaml.safe_load(open(sys.argv[2]))
boards = cat.get('boards') or {}
# find a part carried by TWO boards — the ambiguity the rule exists for
by_part = {}
for b, v in boards.items():
    for pt in (v or {}).get('parts') or []:
        by_part.setdefault(pt, []).append(b)
shared = sorted((pt, bs) for pt, bs in by_part.items() if len(bs) > 1)
assert shared, "no part is carried by two boards — NC6 would be vacuous"
part, (b1, b2) = shared[0][0], sorted(shared[0][1])[:2]
solo = sorted(pt for pt, bs in by_part.items() if len(bs) == 1)
assert solo, "no part carried by exactly one board — NC6b would be vacuous"

def base():
    r = yaml.safe_load(yaml.dump(reg)); r['devices'] = {}
    return r
# (a) AMBIGUOUS: both carriers registered, and the shared part aliased on one
a = base(); a['devices'][b1] = {'what': 'x', 'aliases': [part]}; a['devices'][b2] = {'what': 'y'}
yaml.safe_dump(a, open(sys.argv[3], 'w'))
# (b) UNAMBIGUOUS: only one carrier registered -> must be ACCEPTED
b = base(); b['devices'][b1] = {'what': 'x', 'aliases': [part]}
yaml.safe_dump(b, open(sys.argv[4], 'w'))
# (c) MISLEADING: the alias sits on a device that does NOT carry that part
solo_part = solo[0]; solo_board = by_part[solo_part][0]
other = next(x for x in boards if x != solo_board)
c = base(); c['devices'][other] = {'what': 'x', 'aliases': [solo_part]}
c['devices'][solo_board] = {'what': 'y'}
yaml.safe_dump(c, open(sys.argv[5], 'w'))
print(f"  (NC6 uses shared part '{part}' on {b1}/{b2}; NC6c uses '{solo_part}')")
PYNC4
  if run_check "$CAT" "$t/alias-ambig.yaml" >/dev/null 2>&1; then
    echo "  NC6 FAILED: an alias naming a part carried by TWO registered devices was allowed"
    rm -rf "$t"; exit 1
  fi
  echo "  NC6 ok: an alias reaching two boards on one host is refused (gale#397's actual shape)"
  if ! run_check "$CAT" "$t/alias-one.yaml" >/dev/null 2>&1; then
    echo "  NC6b FAILED: an UNAMBIGUOUS part alias was refused — the rule is too strict, and it"
    echo "    would break the five committed f100 scripts that pass 'stlink-v1' as a device name"
    rm -rf "$t"; exit 1
  fi
  echo "  NC6b ok: a part alias reaching exactly ONE registered board is ACCEPTED"
  if run_check "$CAT" "$t/alias-wrong.yaml" >/dev/null 2>&1; then
    echo "  NC6c FAILED: an alias naming another device's part was allowed"
    rm -rf "$t"; exit 1
  fi
  echo "  NC6c ok: an alias naming a part its own device does not carry is refused"

  # NC7 — THE CONTROL ON NC5/NC6. If assertion 1b refused any name at all, NC5 and NC6 would
  # pass while saying nothing. A device named after a BOARD must still be ACCEPTED.
  if ! run_check "$CAT" "$REG" >/dev/null 2>&1; then
    echo "  NC7 FAILED: the real registry (board names) was refused — 1b rejects too much"
    rm -rf "$t"; exit 1
  fi
  echo "  NC7 ok: a device named after a BOARD is still accepted (1b is not a blanket refusal)"

  # NC8 covers assertion 1c. Built by DELETING a serial from the real catalogue, so it cannot
  # drift from the section it guards.
  python3 - "$CAT" "$t/cat-noserial.yaml" <<'PYNC3'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
st = c.get('standalone') or {}
assert st, "no standalone: section — NC8 would be vacuous"
k = sorted(st)[0]
assert st[k].get('serial'), f"standalone/{k} has no serial to remove — NC8 would be vacuous"
del st[k]['serial']
yaml.safe_dump(c, open(sys.argv[2], 'w'))
print(f"  (NC8 strips the serial from standalone/{k})")
PYNC3
  if run_check "$t/cat-noserial.yaml" "$REG" >/dev/null 2>&1; then
    echo "  NC8 FAILED: a standalone entry with no serial did not trip the check"
    rm -rf "$t"; exit 1
  fi
  echo "  NC8 ok: a standalone entry without a serial is refused (it is a model name in disguise)"
  rm -rf "$t"
  echo "== the real thing =="
fi

run_check "$CAT" "$REG"
rc=$?
[ "$rc" -eq 0 ] && echo "CATALOG OK — names and aliases resolve unambiguously, provenance exists." \
                || echo "CATALOG FAIL"
exit $rc
