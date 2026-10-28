#!/usr/bin/env bash
# Did the Renode model BOOT on this exact commit? Answered from GitHub's record of the ci.yml run,
# so the release run itself never executes Renode or pip.
#
#   ci-gate.sh <owner/repo> <commit-sha>
#
# WHY THIS EXISTS. Booting the model runs third-party code (Renode itself; since #299's no-Python
# decision it needs no pip packages, but Renode is still downloaded code).
# Running that inside the release workflow put it in the same run as the signing job — and a run's
# artifact store is shared by every job in it regardless of `permissions:`, so a compromised
# dependency could upload an artifact the signing job then swept up and signed (security review,
# 2026-10-27). ci.yml already packs and boots the model on every commit to main, in its OWN run
# with its own artifact store. So the release asks that run's result instead of re-running it.
#
# PRECISE, not "CI was green": requires a COMPLETED ci.yml run for EXACTLY this sha whose job
# "Renode RT1176 smoke (REQ-PIX-005)" contains the step "Renode model asset …" with conclusion
# success. A green run on a commit whose ci.yml lacked the step does not count (that would be a
# gate passing over a check that never ran).
#
# Exit 0 = the model step ran and succeeded on this sha.
# Exit 1 = it ran and did NOT succeed, or the job ran without the step.
# Exit 2 = could not determine: no completed ci.yml run for this sha (e.g. CI still running).
set -uo pipefail
REPO="${1:?owner/repo}"; SHA="${2:?commit sha}"
JOB="Renode RT1176 smoke (REQ-PIX-005)"
STEP_PREFIX="Renode model asset"

runs=$(gh api "repos/$REPO/actions/workflows/ci.yml/runs?head_sha=$SHA&status=completed&per_page=20" \
        --jq '.workflow_runs[] | "\(.id) \(.conclusion) \(.event)"' 2>/dev/null) \
  || { echo "CANNOT DETERMINE: the Actions API did not answer for $SHA"; exit 2; }
[ -n "$runs" ] || { echo "CANNOT DETERMINE: no COMPLETED ci.yml run for $SHA yet — wait for CI on this commit, then re-run the release"; exit 2; }

seen=0
while read -r id concl ev; do
  seen=$((seen+1))
  j=$(gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" \
        --jq ".jobs[] | select(.name==\"$JOB\") | .id" 2>/dev/null | head -1)
  [ -n "$j" ] || { echo "  run $id ($ev): no job '${JOB}'"; continue; }
  st=$(gh api "repos/$REPO/actions/jobs/$j" \
        --jq ".steps[] | select(.name | startswith(\"$STEP_PREFIX\")) | .conclusion" 2>/dev/null | head -1)
  if [ -z "$st" ]; then echo "  run $id ($ev): job ran WITHOUT the step '${STEP_PREFIX}…' — that commit's ci.yml predates it"; continue; fi
  if [ "$st" = success ]; then
    echo "OK: ci.yml run $id ($ev) on $SHA — '${STEP_PREFIX}…' concluded success"
    exit 0
  fi
  echo "  run $id ($ev): the model step concluded '$st'"
done <<< "$runs"
echo "FAIL: $seen completed ci.yml run(s) for $SHA; none has the model step succeeding"
exit 1
