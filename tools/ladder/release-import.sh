#!/usr/bin/env bash
# Fetch the O1 ladder file that ci.yml generated on EXACTLY this commit, check it, and stamp it
# with the release version, ready for SHA256SUMS and cosign.
#
#   release-import.sh <owner/repo> <commit-sha> <release-version> <out-dir>
#
# WHY IT IS FETCHED, NOT GENERATED HERE. The judge needs the fused module and a wasmtime reference,
# which is downloaded third-party code. Running that in the release run would put it beside the
# signing job, and a run's artifact store is shared by every job in it (security review,
# 2026-10-27; same reason as tools/renode-model/ci-gate.sh). ci.yml already runs the judge on
# every commit to main in its own run. So the signing job downloads that run's artifact
# directly with gh, and it never passes through this run's artifact store. Only gh and jq run.
#
# PRECISE: requires a completed ci.yml PUSH run for this sha whose job "$JOB" has the step
# "$STEP_PREFIX…" concluded success, and an artifact "north-star-input" holding exactly one file,
# north-star-input.O1.json, generated for this sha (version 0.0.0-ci.<sha12>).
# The only edit is .version, from the CI label to the release version. Facts are untouched.
#
# Exit 0 = file written. Exit 1 = a run exists but the file is missing, failed, or malformed.
# Exit 2 = could not determine (no completed run for this sha yet, or the API did not answer).
set -uo pipefail
REPO="${1:?owner/repo}"; SHA="${2:?commit sha}"; VERSION="${3:?release version}"; OUT="${4:?out dir}"
JOB="on-target cascade oracles (TEST-PIX-032 / TEST-PIX-033)"
STEP_PREFIX="ladder result for this commit"
NAME="north-star-input.O1.json"
fail() { echo "FAIL: $*"; exit 1; }

runs=$(gh api "repos/$REPO/actions/workflows/ci.yml/runs?head_sha=$SHA&event=push&status=completed&per_page=20" \
        --jq '.workflow_runs[] | .id' 2>/dev/null) \
  || { echo "CANNOT DETERMINE: the Actions API did not answer for $SHA"; exit 2; }
[ -n "$runs" ] || { echo "CANNOT DETERMINE: no completed ci.yml push run for $SHA yet; wait for CI on main, then re-run the release"; exit 2; }

run=""; seen=0
for id in $runs; do
  seen=$((seen+1))
  j=$(gh api "repos/$REPO/actions/runs/$id/jobs?per_page=100" \
        --jq ".jobs[] | select(.name==\"$JOB\") | .id" 2>/dev/null | head -1)
  [ -n "$j" ] || { echo "  run $id: no job '$JOB'"; continue; }
  st=$(gh api "repos/$REPO/actions/jobs/$j" \
        --jq ".steps[] | select(.name | startswith(\"$STEP_PREFIX\")) | .conclusion" 2>/dev/null | head -1)
  [ -n "$st" ] || { echo "  run $id: job ran without the step '$STEP_PREFIX…' (its ci.yml predates it)"; continue; }
  [ "$st" = success ] || { echo "  run $id: the ladder step concluded '$st'"; continue; }
  run="$id"; break
done
[ -n "$run" ] || fail "$seen completed ci.yml push run(s) for $SHA; none has the ladder step succeeding"

DL="$(mktemp -d)"; trap 'rm -rf "$DL"' EXIT
gh run download "$run" --repo "$REPO" --name north-star-input --dir "$DL" \
  || fail "run $run: could not download the artifact 'north-star-input'"
got=$(cd "$DL" && find . -type f | sed 's|^\./||' | sort)
[ "$got" = "$NAME" ] || fail "run $run: artifact holds '$(echo $got)', expected exactly $NAME"

F="$DL/$NAME"
jq -e --arg repo "$REPO" --arg v "0.0.0-ci.${SHA:0:12}" '
    .schema_version == 1 and .objective == "O1" and .repo == $repo and .version == $v
    and ([.facts[].id] | sort) == (["flight","hil","r0","real-drone"] | map("pixhawk-6xrt/" + .) | sort)
    and all(.facts[]; (.ran | type) == "boolean" and (.pass | type) == "boolean")
    and all(.facts[]; .pass == false or .ran == true)' "$F" >/dev/null \
  || fail "run $run: $NAME is not an O1 ladder for $REPO at ${SHA:0:12} (schema_version, objective, repo, version, the four rungs, or a pass without a run)"

mkdir -p "$OUT"
jq --arg v "$VERSION" '.version = $v' "$F" > "$OUT/$NAME" || fail "could not write $OUT/$NAME"
echo "OK: $NAME from ci.yml run $run on ${SHA:0:12}, version set to $VERSION"
jq -r '.facts[] | "  \(.id): ran=\(.ran) pass=\(.pass)"' "$OUT/$NAME"
