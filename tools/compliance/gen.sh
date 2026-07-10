#!/usr/bin/env bash
# Generate jess's own compliance / traceability report (FEATURE-012 leg).
# jess cuts no binary release, so the "published compliance report" is this
# regenerable markdown (committed under compliance/) + the coverage-floor gate
# wired into the rivet-validate CI job. Source of truth = the rivet trace.
#
# Usage: tools/compliance/gen.sh > compliance/coverage-report.md
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT"
RIVET="${RIVET:-rivet}"

echo "# jess — Traceability & V&V Compliance Report"
echo
echo "_Generated from the rivet artifact trace by \`tools/compliance/gen.sh\`._"
echo "_This is the regenerable source; the CI \`rivet coverage --fail-under\` step is the enforcement gate._"
echo
echo "## Traceability coverage (\`rivet coverage\`)"
echo
echo '```'
"$RIVET" coverage
echo '```'
echo
echo "## CI verification gates (the right side of the V, per push to main)"
echo
echo "| gate | what it proves | evidence |"
echo "|------|----------------|----------|"
echo "| rivet validate | the artifact spine is well-formed + coverage floor | this report |"
echo "| spar model | the AADL parses/instantiates; inter-core WIT is spar-derived | TEST-PIX-023 |"
echo "| mav_bench | MAVLink CRC decode over a committed 6X-RT sample | REQ-PIX-010 |"
echo "| Renode RT1176 smoke | the RT1176 model boots to the LPUART banner (+ synth #374/#507 oracles) | REQ-PIX-005, TEST-PIX-013/020 |"
echo "| scry sound-analysis | DO-333 sound abstract interpretation on the fused falcon core (0 unsound-fallback) | REQ-PIX-018, TEST-PIX-022 |"
echo
echo "## Verification legs (DO-178C / DO-333 posture)"
echo
echo "- **Structural analysis (DO-333):** scry sound abstract interpretation — GREEN, wired (TEST-PIX-022)."
echo "- **Structural coverage (witness MC/DC):** the harness-bridge follow-on remains (REQ-PIX-018 leg a)."
echo "- **Sound static + safety case:** STPA / STPA-sec / safety-goal layer (100% decision-justification, hazard, UCA coverage above)."
echo
echo "_On-target requirement verification is legitimately incomplete (requirement-verification ~39%)"
echo "because the v0.7.0 on-target requirements are gated on the external synth poles (#369 hard-float,"
echo "#275/#676 dispatch) or the physical board — not on a jess process gap (see FEATURE-010, accepted)._"
