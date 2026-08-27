#!/usr/bin/env bash
# Report toolchain DRIFT across the three places a jess tool version can come from,
# and fail if they disagree.
#
# WHY THIS EXISTS: on 2026-08-27 jess filed meld#390 against meld 0.41.3 while 0.52.0
# was latest — eleven minor versions — and nothing noticed, because the three sources
# below were never compared to each other:
#
#   (1) PATH        what a developer (or an agent) actually runs locally
#   (2) varve pin   what varve.toml says this project is qualified against
#   (3) ci.yml env  what CI actually downloads and runs
#
# All three disagreed. A pin that nothing checks is decoration, so this is the check.
# See AFD-045.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CI="$ROOT/.github/workflows/ci.yml"
drift=0

ci_pin() { # tool -> the version ci.yml downloads, or empty
  local var; var="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_VERSION"
  sed -n "s/^[[:space:]]*${var}:[[:space:]]*v\{0,1\}\([0-9][^[:space:]]*\).*/\1/p" "$CI" | head -1
}
ver() { "$@" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }

printf '%-8s  %-12s  %-12s  %-12s  %s\n' TOOL PATH VARVE-PIN CI-YML STATUS
for t in rivet spar meld synth loom sigil; do
  p="$(ver "$t")"
  v="$(varve run "$t" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  c="$(ci_pin "$t")"
  # Compare only the sources that actually exist. A tool absent from a source is not
  # drift — spar is legitimately not on this machine's PATH, and not every tool is
  # pinned in ci.yml. Treating absence as disagreement would make this cry wolf.
  seen=(); [ -n "$p" ] && seen+=("$p"); [ -n "$v" ] && seen+=("$v"); [ -n "$c" ] && seen+=("$c")
  uniq_n=$(printf '%s\n' "${seen[@]:-}" | sort -u | grep -c . || true)
  # A tool present in NO source is "absent", not "ok". Scoring it ok would be a vacuous
  # pass — it reports agreement where nothing was compared, which is how a checker ends
  # up green on a toolchain it never looked at.
  if   [ "${uniq_n:-0}" -eq 0 ]; then st="absent (not checked)"
  elif [ "${uniq_n:-0}" -eq 1 ]; then st="ok"
  else st="DRIFT"; drift=1; fi
  printf '%-8s  %-12s  %-12s  %-12s  %s\n' "$t" "${p:--}" "${v:--}" "${c:--}" "$st"
done

echo
if [ "$drift" -ne 0 ]; then
  cat <<'MSG'
DRIFT: at least one tool resolves to different versions depending on where you look.
Reconcile before reporting any result upstream — a defect report cites a version, and
a wrong citation costs a supplier's attention (AFD-045, meld#390).
  varve run <tool> ...   runs the PINNED binary regardless of PATH
  varve verify           re-checks the pinned layer and reports PATH shadowing
MSG
  exit 1
fi
echo "no drift: every tool agrees across the sources that define it."
echo "(rows marked 'absent (not checked)' were compared against nothing — they are not evidence.)"
