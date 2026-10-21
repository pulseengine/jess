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

# The CAMPAIGN pin: the version tools/deps/artifacts.pins names for this tool.
#
# This column exists because the varve LAYER is not always jess's authority. artifacts.pins
# says so in its own words for synth ("NOT varve-pinned: the varve layer carries synth 0.58.0
# while the campaign runs 0.64.0"), and meld joined it when jess bumped past three defects the
# layer's build still contains. Comparing ci.yml against the LAYER for such a tool asks the
# wrong question and reports a deliberate, verified decision as BLOCKING drift.
# Found when exactly that happened to the meld 0.55.1 bump.
campaign_pin() { # tool -> version named by artifacts.pins, or empty
  # Key off the RELEASE REF, not the store path: the path prefix need not equal the tool
  # name (synth is stored under `synthpin/` precisely so the directory carries no version).
  sed -n "s|.*release:pulseengine/$1@v\{0,1\}\([0-9][^!]*\)!.*|\1|p" \
    "$ROOT/tools/deps/artifacts.pins" 2>/dev/null | head -1
}

# ── --committed-only: THE ONE ASSERTION THAT NEEDS NO VARVE ──────────────────────────────────
# ci.yml-versus-artifacts.pins is a comparison between TWO COMMITTED FILES. It needs no layer,
# no network and no varve. But it used to sit BEHIND the varve gate below, so on any machine
# without varve — which is every CI runner, as ci.yml's own comments state — the whole script
# refused with rc=2 and the comparison never ran.
#
# AND ci.yml CLAIMED IT RAN. Five comments there cite this script as the thing keeping
# MELD_VERSION in lockstep with the pin, one of them in these words: "check-drift.sh reports a
# ci-vs-pin disagreement as BLOCKING, so these two moving apart is a red board, not a silent
# drift." That sentence was FALSE: nothing invoked this script anywhere, so drift was exactly a
# silent drift. Measured 2026-10-15 by creating one — bumping the meld pin to 0.62.0 while
# ci.yml still said v0.58.3 — and watching a PR go green.
#
# So the committed-file comparison is now separable and is wired into CI. The varve-layer
# columns stay behind the refusal below, because a verdict about a layer this script could not
# read would be the vacuity the refusal exists to prevent. Two questions, two reachabilities.
if [ "${1:-}" = "--committed-only" ]; then
  echo "== ci.yml vs tools/deps/artifacts.pins (committed files only, no varve needed) =="
  cmp_n=0; bad=0
  # Every tool artifacts.pins names by a release ref. Derived from the file, not a hand-kept
  # list, so a newly pinned tool is covered without editing this script.
  tools="$(sed -n 's|.*release:pulseengine/\([a-z][a-z0-9-]*\)@.*|\1|p' \
            "$ROOT/tools/deps/artifacts.pins" 2>/dev/null | sort -u)"
  for t in $tools; do
    cp_="$(campaign_pin "$t")"; cip="$(ci_pin "$t")"
    [ -n "$cp_" ] || continue
    if [ -z "$cip" ]; then
      printf '  %-8s pin %-10s ci.yml <no %s_VERSION>  not compared\n' \
        "$t" "$cp_" "$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')"
      continue
    fi
    cmp_n=$((cmp_n+1))
    if [ "$cp_" = "$cip" ]; then
      printf '  %-8s pin %-10s ci.yml %-10s AGREE\n' "$t" "$cp_" "$cip"
    else
      printf '  %-8s pin %-10s ci.yml %-10s DRIFT-BLOCKING\n' "$t" "$cp_" "$cip"
      bad=$((bad+1))
    fi
  done
  # COVERAGE IS REPORTED, NOT IMPLIED. The loop above derives its tool list from
  # artifacts.pins, so a tool ci.yml pins that artifacts.pins does NOT name is never compared —
  # and the old summary said "N tool(s) compared, all agree", which reads as completeness.
  # MEASURED within an hour of shipping this gate: ci.yml pins RIVET_VERSION v0.35.0 and
  # SPAR_VERSION v0.40.0, neither is in artifacts.pins, so the gate compared 1 of 3 and
  # reported "all agree". That is the same shape as the three findings this gate came FROM
  # (AFD-135/136/137): a check whose green is true of what it looked at and silent about the
  # rest. Not blocking — artifacts.pins is for build-chain artifacts and CI legitimately pins
  # tools outside it — but it must be SAID.
  uncovered=""
  for v in $(grep -oE '^[[:space:]]*[A-Z0-9_]+_VERSION:' "$CI" | tr -d ' :' | sed 's/_VERSION//' | sort -u); do
    lt="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
    [ -n "$(campaign_pin "$lt")" ] && continue
    cv="$(ci_pin "$lt")"
    [ -n "$cv" ] || continue
    uncovered="$uncovered $lt=$cv"
  done
  if [ -n "$uncovered" ]; then
    echo "  NOT COVERED by this check (ci.yml pins them, artifacts.pins does not name them):"
    for u in $uncovered; do
      printf '    %-18s no campaign pin to compare against\n' "$u"
    done
    echo "    Legitimate — artifacts.pins is for build-chain artifacts — but this check says"
    echo "    NOTHING about these versions, and the count below is of what it DID compare."
  fi
  if [ "$cmp_n" -eq 0 ]; then
    echo "  REFUSING: compared NOTHING — no tool is named in both files, so a pass here would"
    echo "  be a verdict about an empty set. Either artifacts.pins names no release refs or the"
    echo "  <TOOL>_VERSION convention changed."
    exit 2
  fi
  if [ "$bad" -ne 0 ]; then
    echo
    echo "DRIFT-BLOCKING: ci.yml and the campaign pin disagree for $bad of $cmp_n tool(s)."
    echo "  Both sources are COMMITTED, so this is not an environment problem — fix one of them."
    echo "  CI would otherwise qualify this project against a toolchain no committed file claims"
    echo "  (AFD-045, AFD-137)."
    exit 1
  fi
  nunc=$(printf '%s' "$uncovered" | wc -w | tr -d ' ')
  echo "  $cmp_n tool(s) compared, all agree; $nunc ci.yml-pinned tool(s) NOT COVERED (above)."
  exit 0
fi

# REFUSE if varve cannot resolve the layer at all.
#
# The 2026.09.2 migration made this concrete: the new varve-realms.toml carries `retired-roots`,
# which a varve < 0.33.0 cannot parse, so EVERY `varve run` failed and the VARVE-LAYER column
# read `-` for every tool — and this script reported "no blocking drift", exit 0. A green
# verdict produced by a broken toolchain rather than by agreement, which is the vacuity class
# this repo keeps finding in checkers. Fail loudly and name the cause instead.
if ! varve which rivet >/dev/null 2>&1 && ! varve which meld >/dev/null 2>&1; then
  echo "CANNOT RESOLVE THE VARVE LAYER — refusing to report a drift verdict." >&2
  varve which rivet 2>&1 | head -3 | sed 's/^/  /' >&2
  echo "  A 'no drift' result here would be a verdict about a toolchain this script could not" >&2
  echo "  read. If the realms file mentions retired-roots, varve must be >= 0.33.0." >&2
  exit 2
fi

compared=0; single=0; advisory=0; cipin=0; nocipin=""; ahead=""; behind=""
printf '%-8s  %-11s  %-11s  %-11s  %-11s  %s\n' TOOL PATH VARVE-LAYER CAMPAIGN CI-YML STATUS
for t in rivet spar meld synth loom sigil; do
  p="$(ver "$t")"
  v="$(varve run "$t" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  c="$(ci_pin "$t")"
  cp="$(campaign_pin "$t")"
  # The AUTHORITY for a ci.yml comparison is the campaign pin when artifacts.pins names the
  # tool, and the varve layer otherwise.
  auth="${cp:-$v}"; authname="campaign"; [ -n "$cp" ] || authname="varve-layer"
  # Compare only the sources that actually exist; not every tool is pinned in ci.yml,
  # and treating absence as disagreement would make this cry wolf.
  #
  # CAVEAT, found by clean-room verification and NOT yet fixed: `ver` reads a version by
  # running `<tool> --version`. Tools that do not support that flag (spar, ordeal) read as
  # absent even though the binary IS on PATH — so a PATH binary at a wildly divergent
  # version silently drops OUT of the comparison. That is the inverse of crying wolf and
  # is the more dangerous direction. `varve verify` currently reports 7 shadowed tools.
  seen=(); [ -n "$p" ] && seen+=("$p"); [ -n "$v" ] && seen+=("$v"); [ -n "$c" ] && seen+=("$c")
  uniq_n=$(printf '%s\n' "${seen[@]:-}" | sort -u | grep -c . || true)
  # A tool present in NO source is "absent", not "ok". Scoring it ok would be a vacuous
  # pass — it reports agreement where nothing was compared, which is how a checker ends
  # up green on a toolchain it never looked at.
  #
  # Clean-room verification found this stopped one step short in two ways, both fixed:
  #   - a tool found in exactly ONE source also scored "ok" — one value compared against
  #     nothing is not agreement either. It is now "single-source (not compared)".
  #   - if EVERY tool was absent the script still exited 0 with "no drift", i.e. a green
  #     verdict on a toolchain it never inspected. Tracked below and now an error.
  # SEVERITY SPLIT. One undifferentiated "DRIFT" conflated two very different things,
  # and the row that mattered was invisible inside the row that never goes away:
  #
  #   BLOCKING  ci.yml != varve pin. CI qualifies the project against a DIFFERENT
  #             toolchain than the pin claims. Both are committed files, so this is
  #             actionable and can actually be driven to green.
  #   ADVISORY  only PATH disagrees. A developer's stale shell binary. It cannot be
  #             fixed by editing the repo, so it is permanently red on any machine
  #             without varve shims — which is why the single verdict carried no
  #             information and went unread for weeks.
  #
  # PATH still MATTERS: it is what caused meld#390 (a report filed against the PATH
  # binary's version). So advisory is loud, and --strict still fails on it. What
  # changed is that it no longer masks the blocking class.
  n_sources=${#seen[@]}
  if   [ "${uniq_n:-0}" -eq 0 ]; then st="absent (not checked)"
  elif [ "$n_sources" -eq 1 ]; then st="single-source (not compared)"; single=$((single+1))
  elif [ "${uniq_n:-0}" -eq 1 ]; then
    st="ok"; compared=$((compared+1))
    # An all-agree row is still a ci-vs-pin comparison when both are declared — count it,
    # or the summary under-reports what it actually checked.
    if [ -n "$auth" ] && [ -n "$c" ]; then cipin=$((cipin+1)); else nocipin="$nocipin $t"; fi
  elif [ -n "$auth" ] && [ -n "$c" ] && [ "$auth" != "$c" ]; then
    st="DRIFT-BLOCKING (ci.yml != $authname)"; drift=1; compared=$((compared+1)); cipin=$((cipin+1))
  else
    st="drift-advisory (PATH only)"; advisory=$((advisory+1)); compared=$((compared+1))
    # Count the ci-vs-pin comparison ONLY when BOTH sources exist. A row with just PATH and
    # the varve pin is a two-source row, but it says NOTHING about ci.yml — and the summary
    # used to claim "ci.yml and the varve pin agree" for exactly those rows. That went
    # unnoticed until removing ci.yml's SYNTH_VERSION made synth and loom read `-` here while
    # the prose still asserted agreement for them. Found by clean-room verification.
    if [ -n "$auth" ] && [ -n "$c" ]; then cipin=$((cipin+1)); else nocipin="$nocipin $t"; fi
    # Report the campaign/layer gap in BOTH directions. Only reporting "ahead" made a
    # campaign pin that had fallen BEHIND the layer invisible — and behind is the direction
    # that silently misses a fix, which is the worse one.
    if [ -n "$cp" ] && [ -n "$v" ] && [ "$cp" != "$v" ]; then
      newest="$(printf '%s\n%s\n' "$cp" "$v" | sort -V | tail -1)"
      if [ "$newest" = "$cp" ]; then ahead="$ahead $t(layer $v -> campaign $cp)"
      else behind="$behind $t(campaign $cp < layer $v)"; fi
    fi
  fi
  printf '%-8s  %-11s  %-11s  %-11s  %-11s  %s\n' "$t" "${p:--}" "${v:--}" "${cp:--}" "${c:--}" "$st"
done

echo
if [ "$advisory" -gt 0 ]; then
  echo "ADVISORY: $advisory tool(s) differ on PATH from the pin."
  echo "  Harmless for the BUILD (scripts resolve explicitly or via varve), but it is exactly"
  echo "  what produced meld#390: a defect filed against the PATH binary's version."
  echo "  Before citing ANY version upstream, quote \`varve run <tool> --version\`, not PATH."
fi
if [ "$drift" -ne 0 ]; then
  cat <<'MSG'

DRIFT-BLOCKING: ci.yml disagrees with the AUTHORITATIVE pin for a tool (the STATUS column
names which authority was used: the campaign pin in tools/deps/artifacts.pins where it names
the tool, otherwise the varve layer). CI is qualifying this project against a toolchain no
committed file claims, so a green board is a verdict about a toolchain nobody declared.
Both sources are committed — fix one of them (AFD-045).
  varve run <tool> ...   runs the PINNED binary regardless of PATH
  varve verify           re-checks the pinned layer and reports PATH shadowing
MSG
  exit 1
fi
if [ -n "${STRICT:-}" ] && [ "$advisory" -gt 0 ]; then
  echo "STRICT: advisory drift is fatal in this mode (use before citing a version upstream)." >&2
  exit 1
fi
if [ "$compared" -eq 0 ]; then
  echo "NOTHING WAS ACTUALLY COMPARED: no tool was found in two or more sources." >&2
  echo "A 'no drift' verdict here would be green on a toolchain never inspected." >&2
  exit 2
fi
echo "no blocking drift: ci.yml agrees with the authoritative pin for the $cipin tool(s) compared."
if [ -n "$ahead" ]; then
  echo "CAMPAIGN AHEAD OF THE VARVE LAYER (deliberate, see artifacts.pins):$ahead"
  echo "  Not drift: artifacts.pins is the authority for these, and the reason is recorded there."
fi
if [ -n "$behind" ]; then
  echo "CAMPAIGN PIN BEHIND THE VARVE LAYER:$behind"
  echo "  Not blocking — artifacts.pins is the authority — but this is the direction that"
  echo "  silently misses an upstream fix. Worth a release-watch, not a shrug."
fi
if [ -n "$nocipin" ]; then
  echo "NOT COMPARED against ci.yml (no *_VERSION there):$nocipin"
  echo "  These rows say nothing about CI. Claiming agreement for them would be a verdict"
  echo "  about a comparison that never happened."
fi
[ "$single" -gt 0 ] && echo "($single row(s) 'single-source' and any 'absent' rows were compared against nothing — not evidence.)"
exit 0
