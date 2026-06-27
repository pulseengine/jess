#!/usr/bin/env bash
# rivet sql snapshot — the jess loop's standing visibility query.
#
# Two read-only projections over the rivet artifact store (rivet >= 0.20.0,
# `rivet sql`, REQ-229 / DD-068):
#
#   1. Punch-list  — every open ai-found-defect (the live defect backlog;
#                    the falcon-on-target poles live here as AFD rows).
#   2. V-gap       — non-draft requirements (implemented/verified/accepted)
#                    that NO test-spec `verifies`. A non-empty V-gap means a
#                    requirement claims done with the right side of the V open.
#   3. Release readiness — `rivet release status` (rivet >= 0.22.0) burn-down for
#                    the next planned releases (REQ-233 / DD-021). Shown for
#                    visibility; the EXIT-CODED form `rivet release status vX.Y`
#                    is the pre-tag cut gate (it exits non-zero when not cuttable),
#                    run at release time — NOT on every PR.
#
# Non-gating by design: this reports state, it does not fail the build. The
# gate is `rivet validate`. Run locally in the release-watch loop, or in CI
# where the output is appended to the job summary.
#
# Usage: tools/rivet/snapshot.sh [rivet-binary]   (default: rivet on PATH)
set -euo pipefail

RIVET="${1:-rivet}"

PUNCHLIST_SQL="SELECT id, status, title FROM artifacts \
WHERE type='ai-found-defect' AND status='open' ORDER BY id"

VGAP_SQL="SELECT id, status, title FROM artifacts \
WHERE type='requirement' AND status IN ('implemented','verified','accepted') \
AND id NOT IN (SELECT target FROM links WHERE link_type='verifies') \
ORDER BY status, id"

echo "## rivet sql snapshot"
echo
echo "_rivet $("$RIVET" --version 2>/dev/null | awk '{print $2}') — \`rivet sql\` over the artifact spine_"
echo
echo "### Punch-list — open ai-found-defects"
echo '```'
"$RIVET" sql "$PUNCHLIST_SQL"
echo '```'
echo
echo "### V-gap — non-draft requirements lacking a verifying test"
echo '```'
"$RIVET" sql "$VGAP_SQL"
echo '```'
echo
echo "### Release readiness — rivet release status (informational; cut gate is the exit code)"
echo '```'
for v in v0.6.0 v0.7.0 v0.8.0 v0.9.0; do
  "$RIVET" release status "$v" 2>&1 || true
  echo
done
echo '```'
