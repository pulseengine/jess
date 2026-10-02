#!/usr/bin/env bash
# Refuse the ONE combination varve v0.32.1's rotation makes silently fatal:
# a trust root that cannot verify the layer this project is pinned to.
#
# WHY THIS EXISTS. On 2026-09-07 varve rotated the rolling trust root
# (4e771dc6... -> 7d3b892e...). Layers 2026.08.0 .. 2026.09.1 are signed by the OLD
# root; 2026.09.2 will be the first signed by the NEW one. varve's own guidance to a
# consumer pinned below that boundary is: DO NOTHING.
#
# The hazard is that doing the wrong thing looks trivial. The published
# varve-realms.toml is BYTE-IDENTICAL to the one in this repo except for the
# trust-root line — verified, `diff` is empty once that line is masked. So "vendor the
# new realms file" reads as a one-line no-op diff in review, and produces:
#
#     error: manifest signature verification failed: ... No valid signatures
#
# This repo runs an autonomous loop that bumps pins on evidence. A rule that lives only
# in a release note is a rule the loop will not see. This is that rule, executable.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
REALMS="${REALMS:-$ROOT/varve-realms.toml}"
PIN="${PIN:-$ROOT/varve.toml}"

OLD_ROOT=4e771dc62a08be89e3450f8cd807da58ff70af4a4e124ebf2d2b71684cfd9973
NEW_ROOT=7d3b892e6a33c70043becc708e08042e1cef0d54dd5ae6f23d7d4c68de1da1a0
# The boundary is a varve FACT, not a jess preference: the first layer signed by the
# new root. Layers sort lexically here because they are zero-padded YYYY.MM.N.
FIRST_NEW_ROOT_LAYER=2026.09.2

verdict() { # $1=root $2=layer  -> prints OK/FAIL reason, returns 0/1
  local root="$1" layer="$2" era
  if [ "$root" = "$OLD_ROOT" ]; then era=old
  elif [ "$root" = "$NEW_ROOT" ]; then era=new
  else echo "UNKNOWN trust root $root — neither the pre- nor post-rotation value"; return 1; fi
  # String compare is wrong across a component boundary (2026.09.10 vs 2026.09.2), so
  # compare the numeric triple.
  local a b; a=$(printf '%s' "$layer" | awk -F. '{printf "%04d%02d%03d",$1,$2,$3}')
  b=$(printf '%s' "$FIRST_NEW_ROOT_LAYER" | awk -F. '{printf "%04d%02d%03d",$1,$2,$3}')
  if [ "$a" -ge "$b" ]; then
    [ "$era" = new ] && { echo "OK: layer $layer is post-rotation and the realm carries the NEW root"; return 0; }
    echo "FAIL: layer $layer is signed by the NEW root, but this realm carries the OLD one — it cannot verify"; return 1
  else
    [ "$era" = old ] && { echo "OK: layer $layer is pre-rotation and the realm carries the OLD root"; return 0; }
    echo "FAIL: this realm carries the NEW trust root, but layer $layer was signed by the OLD one.
   varve: 'Every layer published from 2026.08.0 through 2026.09.1 was signed by the old
   root and does not verify against the new one.' Taking the realms file WITHOUT moving
   the pin to >= $FIRST_NEW_ROOT_LAYER leaves this project pinned to a layer its own realm
   cannot verify. Until that layer exists, the correct action is to do NOTHING."; return 1
  fi
}

# ── IS THE PIN OPERATIVE, OR MERELY SELF-CONSISTENT? ────────────────────────────────────────
# The check above compares the realms file's trust root against the pinned layer with `sed`.
# That is an INTERNAL-CONSISTENCY check, and it passes whether or not the installed varve can
# USE the file at all. Measured on 2026-10-02: this gate was green while every `varve run`
# failed outright —
#     error: varve-realms.toml: not a valid realms file: TOML parse error at line 21
#            unknown field `retired-roots`, expected one of `registry`, `trust-root`, ...
# because the committed realms file is varve's own CURRENT published one (it still ships
# `retired-roots` in v0.39.0) while the installed binary was v0.29.0, which predates the field.
# `retired-roots` is documented in that very file as "DIAGNOSTIC ONLY — nothing verifies
# against these, ever", so an optional diagnostic field makes an older varve refuse EVERY
# operation.
#
# WHY THAT MATTERS BEYOND VARVE: hardware/renode/cascade-invoke/build.sh falls back to
# `varve run meld` when MELD is unset, so the DEFAULT build path was broken while the gate that
# exists to protect the toolchain pin reported OK. A gate that checks a file's contents but
# never asks the tool whether it can read the file is the same vacuity this repo keeps finding
# in checkers rather than in code.
classify_varve() { # $1=rc $2=output -> prints a verdict token
  if [ "$1" = 0 ]; then echo OPERATIVE; return; fi
  case "$2" in
    *"not a valid realms file"*|*"unknown field"*) echo REALMS_UNPARSEABLE;;
    *) echo OTHER_FAILURE;;
  esac
}

operative_check() {
  if ! command -v varve >/dev/null 2>&1; then
    # The word OPERATIVE deliberately does NOT appear in this message. It used to —
    # "whether the pin is OPERATIVE could not be determined" — and a grep for the bare token
    # then matched the sentence that says the OPPOSITE of the verdict. My own verification of
    # this branch reported "WRONG: claims OPERATIVE" because of it, which is the same defect
    # this repo has hit in an ABI gate whose reader was redirected by a nearby comment. The
    # verdict tokens OPERATIVE / FAIL / NOT CHECKED now appear only at the start of a verdict
    # line, so a consumer anchoring on `^` cannot be misled by prose.
    echo "NOT CHECKED: varve is not on PATH, so whether the pin is usable could not be
   determined. This is 'could not run', not 'the pin works'."
    return 0          # absence of varve is not this gate's failure; it is reported, not hidden
  fi
  local out rc v
  v="$(varve --version 2>&1 | head -1)"
  out="$(varve which meld 2>&1)"; rc=$?
  case "$(classify_varve "$rc" "$out")" in
    OPERATIVE)
      echo "OPERATIVE: $v can resolve the pin ($(printf '%s' "$out" | head -1))"
      return 0;;
    REALMS_UNPARSEABLE)
      echo "FAIL: $v CANNOT PARSE $REALMS, so the pin is not operative and every
   \`varve run <tool>\` fails. The realms file is varve's own published one and carries a field
   this binary predates:
$(printf '%s' "$out" | sed 's/^/     /' | head -6)
   This is a VERSION SKEW, not a corrupt file. Either upgrade varve, or pin a realms file this
   binary understands — but do NOT delete the field to make the parse succeed: it is varve's,
   and removing it would diverge this repo's realms file from the canonical one, which is the
   AFD-118 trap in reverse.
   Note what it breaks beyond varve: build.sh falls back to \`varve run meld\` when MELD is
   unset, so the default build path is down while this is true."
      return 1;;
    *)
      echo "FAIL: $v could not resolve the pin, for a reason that is not a realms parse error:
$(printf '%s' "$out" | sed 's/^/     /' | head -6)"
      return 1;;
  esac
}

if [ "${1:-}" = "--self-test" ]; then
  ok=0
  # Every row must be OBSERVED to give its stated verdict — including the two failures.
  # A guard whose failing cases were never executed is the vacuity this campaign keeps
  # finding in checkers rather than in code.
  for row in "$OLD_ROOT|2026.08.4|0|pre-rotation pin, old root (the frozen old realm)" \
             "$NEW_ROOT|2026.09.2|0|post-rotation pin, new root (jess today)" \
             "$NEW_ROOT|2026.08.4|1|THE TRAP: new realms file, pin not moved" \
             "$OLD_ROOT|2026.09.2|1|pin moved past the boundary, realm not updated" \
             "deadbeef|2026.08.4|1|unrecognised root"; do
    IFS='|' read -r r l want label <<EOF
$row
EOF
    got=0; out=$(verdict "$r" "$l") || got=1
    if [ "$got" = "$want" ]; then printf "  [ok ] %-42s -> %s\n" "$label" "$(echo "$out" | head -1)"
    else ok=1; printf "  [FAIL] %-42s want rc=%s got rc=%s\n" "$label" "$want" "$got"; fi
  done
  # And the OPERATIVE classifier, exercised on canned varve output so the self-test needs no
  # varve installed. The failure strings are VERBATIM LINES from the terminal on 2026-10-02 —
  # a canned string invented by whoever writes the check tends to match the check rather than
  # reality. One line each rather than the whole multi-line error, because `read` consumes a
  # single line and a multi-line row silently parsed as an EMPTY label and an empty expectation,
  # which the self-test caught as `want <blank> got REALMS_UNPARSEABLE`.
  cls() { # $1=rc $2=output $3=want $4=label
    local got; got="$(classify_varve "$1" "$2")"
    if [ "$got" = "$3" ]; then printf "  [ok ] %-42s -> %s\n" "$4" "$got"
    else ok=1; printf "  [FAIL] %-42s want %s got %s\n" "$4" "$3" "$got"; fi
  }
  cls 0 "layer 2026.09.2 (sha256:abc) meld" OPERATIVE "a working resolve"
  cls 1 "error: /x/varve-realms.toml: not a valid realms file: TOML parse error at line 21" \
        REALMS_UNPARSEABLE "THE MEASURED SKEW, line 1 verbatim"
  cls 1 "unknown field \`retired-roots\`, expected one of \`registry\`, \`trust-root\`" \
        REALMS_UNPARSEABLE "THE MEASURED SKEW, the unknown-field line"
  cls 1 "error: source has no layer matching sha256:c1e6a418" \
        OTHER_FAILURE "a real but different failure"
  cls 1 "error: No valid signatures" \
        OTHER_FAILURE "a verification failure, NOT a parse error"
  # The control that stops the two SKEW rows being vacuous: a success must NOT be classified as
  # a skew however the output reads. Without this, `classify_varve` returning REALMS_UNPARSEABLE
  # unconditionally would pass both of them.
  cls 0 "error: not a valid realms file" OPERATIVE \
        "rc=0 wins over scary text (a pass is a pass)"
  echo "SELF-TEST: $([ $ok = 0 ] && echo PASS || echo FAIL)"; exit $ok
fi

root=$(sed -n 's/^trust-root = "\(.*\)"/\1/p' "$REALMS" | head -1)
layer=$(sed -n 's/^layer[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$PIN" | head -1)
[ -n "$root" ]  || { echo "no trust-root in $REALMS" >&2; exit 2; }
[ -n "$layer" ] || { echo "no layer in $PIN" >&2; exit 2; }
echo "realm trust-root: $root"
echo "pinned layer:     $layer"
out=$(verdict "$root" "$layer"); rc=$?
echo "$out"

# The second, independent question: can the installed varve actually USE this file?
echo
op=$(operative_check); orc=$?
echo "$op"

# Either failure fails the gate. They are separate questions and a reader needs to see which
# one fired, so both verdicts are always printed rather than short-circuiting on the first.
[ "$rc" = 0 ] && [ "$orc" = 0 ] || exit 1
exit 0
