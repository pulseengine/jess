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

# The check itself is the Rust binary built from tools/bench/check-catalog/ (jess#290: jess
# reads its own YAML through rivet's parser, via `rivet yaml to-json`, not PyYAML). It is a
# PORT of the Python this script used to embed; the old script is kept, unchanged, as
# check-catalog.ref.sh, and tools/bench/check-catalog/tests/equivalence.rs asserts the two
# give identical stdout and exit codes. CHECK_CATALOG overrides the binary's path.
BIN=${CHECK_CATALOG:-tools/bench/check-catalog/target/release/check-catalog}

# PREFLIGHT. Name EVERY missing dependency at once, before doing any work — the pattern the
# on-target CI jobs already use. Discovering them one at a time costs a run per gap and names
# only one of them.
preflight() {
  local missing=""
  command -v rivet >/dev/null 2>&1 || missing="$missing rivet"
  [ -x "$BIN" ] || missing="$missing $BIN"
  if [ -n "$missing" ]; then
    echo "  PREFLIGHT FAIL — missing:$missing"
    echo "    This check needs rivet (>= 0.42.2, for \`rivet yaml to-json\`) to read the catalogue"
    echo "    and to confirm every measured-by citation names a real artifact, and the check"
    echo "    binary: cargo build --release --locked --manifest-path tools/bench/check-catalog/Cargo.toml"
    echo "    Refusing to report a pass on claims it could not check."
    return 1
  fi
  return 0
}

# The three assertions, the device-name rule (1b, AFD-136), the standalone-serial rule (1c)
# and the alias ambiguity rule are documented where they are now enforced: src/main.rs.
run_check() {
  "$BIN" check "$1" "$2"
}


preflight || { echo "CATALOG FAIL"; exit 1; }

if [ "${1:-}" = "--self-test" ]; then
  echo "== negative controls: every assertion must be observed to FAIL =="
  t=$(mktemp -d)
  # Rename the registry's FIRST device, whatever it is. This used to rename `pixhawk-6xrt` by
  # literal; once that entry left the registry (AFD-147) the sed matched nothing, the copy was
  # identical to the original, and the control tested the real file. Assert the copy DIFFERS.
  first=$("$BIN" first-device "$REG")
  sed "s/^  ${first}:/  ${first}-typo:/" "$REG" > "$t/reg.yaml"
  if cmp -s "$REG" "$t/reg.yaml"; then
    echo "  NC1 FAILED: the injection did not change the registry — the control would be vacuous"; rm -rf "$t"; exit 1
  fi
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
  "$BIN" fixture-alias "$CAT" "$REG" "$t/alias-unknown.yaml" "$t/alias-collide.yaml" \
    || { echo "  NC3/NC4 FAILED: the fixtures could not be built — the controls would be vacuous"; rm -rf "$t"; exit 1; }
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
  "$BIN" fixture-dev-is-part "$CAT" "$REG" "$t/dev-is-part.yaml" \
    || { echo "  NC5 FAILED: the fixture could not be built — the control would be vacuous"; rm -rf "$t"; exit 1; }
  if run_check "$CAT" "$t/dev-is-part.yaml" >/dev/null 2>&1; then
    echo "  NC5 FAILED: a device named after a PART (a probe model) did not trip the check"
    rm -rf "$t"; exit 1
  fi
  echo "  NC5 ok: a device named after a probe model is refused (jess#266, gale#397)"
  # NC6 group covers the SHARPENED alias rule: ambiguity, not shape. Fixtures are derived from
  # the real catalogue, so they cannot drift from the thing they control. The ambiguous case is
  # REAL — `stlink-v2-1` is carried by two catalogue boards, which is gale#397's actual shape.
  "$BIN" fixture-alias-ambig "$CAT" "$REG" "$t/alias-ambig.yaml" "$t/alias-one.yaml" "$t/alias-wrong.yaml" \
    || { echo "  NC6 FAILED: the fixtures could not be built — the controls would be vacuous"; rm -rf "$t"; exit 1; }
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
  "$BIN" fixture-noserial "$CAT" "$t/cat-noserial.yaml" \
    || { echo "  NC8 FAILED: the fixture could not be built — the control would be vacuous"; rm -rf "$t"; exit 1; }
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
