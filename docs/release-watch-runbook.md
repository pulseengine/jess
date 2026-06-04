---
id: DOC-001
title: Release-Watch Feedback Loop Runbook
type: doc
status: draft
---

# Release-Watch Feedback Loop Runbook

This runbook describes the operational process for monitoring upstream component
releases, triaging changes, exercising the hardware-in-the-loop (HIL) bench, and
feeding findings back to upstream suppliers.

## 1. Maintain and Pin Externals

Keep `externals:` in `rivet.yaml` current with the upstream repos falconeer
consumes. After any change to the externals list, re-sync and re-lock:

```bash
rivet sync          # pull latest external graphs
rivet lock          # write / update rivet.lock with current digests
```

When adopting a new upstream release, re-pin to that release:

```bash
rivet lock --update   # update all pinned digests to latest resolved state
```

Commit both `rivet.yaml` and `rivet.lock` together so the baseline is always
reproducible.

## 2. React to a New Upstream Release or Main Commit

For repos that publish GitHub releases, pull the compliance report asset:

```bash
gh release download v<version> \
  --repo pulseengine/<component> \
  --pattern "<component>-v<version>-compliance-report.tar.gz"
```

For repos without tagged releases (e.g. gale), watch main commits directly.

After fetching the report, inspect what changed:

```bash
rivet snapshot                          # capture current artifact state
rivet diff --base <old-ref> --head <new-ref>   # compare artifact versions
rivet impact --since <old-ref>          # show downstream impact of changes
```

Review the diff output for:
- New, removed, or renamed artifacts
- Changed field values (especially severity, status, priority)
- New or removed links that affect falconeer's traceability chains

## 3. Exercise via the HIL Bench

Phase 1 target: gale STM32F4 / Renode flight_control.

After an upstream change that touches control paths or firmware interfaces, run
the HIL bench and collect results:

```bash
# Run the bench (project-specific command — see docs/getting-started.md)
make hil-run

# Import results into rivet
rivet import-results --format junit ./hil-results/junit.xml
```

Link imported test execution artifacts to the relevant requirement (REQ-001,
REQ-002) automatically via the import-results mapping config, or manually with
`rivet link`.

## 4. Log Findings

Any optimization opportunity, regression, or upstream defect found during the
watch cycle is recorded as an `ai-found-defect` (if detected by rivet tooling)
or a general finding in `artifacts/findings.yaml`.

Required fields for `ai-found-defect`:

| Field | Notes |
|-------|-------|
| `severity` | `critical` / `major` / `minor` / `info` |
| `triage-status` | `open` initially |
| `detected-by` | detection method (e.g., `rivet validate`, manual review) |
| `discovered-at` | ISO date |

Always link the finding to:
1. The relevant supplier anchor (`defect-against: EXTERNALANCHOR-00X`)
2. The affected requirement or test spec (`traces-to: REQ-00X`)

Example:

```bash
# Pre-create the file if it does not exist
# artifacts/findings.yaml must start with `artifacts: []`

rivet add \
  -t ai-found-defect \
  --title "upstream component broken ref in safety analysis" \
  --link "defect-against:EXTERNALANCHOR-002" \
  --link "traces-to:REQ-003"
```

## 5. Feed Back to Upstream

Once a finding is logged:

```bash
gh issue create \
  --repo pulseengine/<component> \
  --title "<short description>" \
  --body "$(cat <<'EOF'
Rivet finding AFD-XXX detected during falconeer external integration.

<description of the issue>

Reference: falconeer artifact AFD-XXX (artifacts/findings.yaml)
EOF
)"
```

Paste the issue URL into the finding's `notes:` field or `description:`. Then
advance the triage lifecycle:

| State | When |
|-------|------|
| `open` | Initially filed |
| `accepted` | Confirmed as a real defect, upstream notified |
| `rejected` | Determined to be falconeer-local, or not a defect |
| `deduplicated` | Covered by an existing upstream issue |

Add a `corrects: AFD-XXX` link on the artifact that eventually fixes the defect
(once the upstream fix is adopted and verified).

## 6. Verify Coverage and Re-Pin on Adoption

After triaging all findings and adopting a fix upstream:

```bash
rivet baseline verify     # confirm no regressions vs. last baseline
rivet supplier check      # check supplier boundary coverage
rivet lock --update       # re-pin to the new release
```

Commit the updated `rivet.lock` with a message referencing the upstream version
adopted.

## 7. Currently-Blocked Components

The following four components are tracked as supplier-boundary anchors because
their upstream rivet graphs do not resolve (as of 2026-06-04). They cannot be
consumed as cross-repo externals until the upstream issues are fixed:

| Component | Anchor | Blocker |
|-----------|--------|---------|
| synth | EXTERNALANCHOR-002 | Broken `CTRL-RA` ref; synth-sigil dependency cycle |
| meld | EXTERNALANCHOR-003 | Broken Fiber Manager refs |
| kiln | EXTERNALANCHOR-004 | Broken `CTRL-BUILTINS` ref |
| sigil | EXTERNALANCHOR-005 | Dangling `kiln:` prefix links; participates in synth-sigil cycle |

The primary finding is recorded as AFD-001 (synth). When an upstream fix is
released, re-attempt `rivet sync` / `rivet lock`, run `rivet validate`, and
promote the anchor status from `accepted` to `verified` once the graph resolves.

## Provenance

Artifacts created during a Claude Code session can be stamped for AI provenance
using:

```bash
rivet stamp <ID> \
  --created-by ai-assisted \
  --model claude-sonnet-4-6 \
  --session-id <session-id>
```

To stamp all artifacts created in the current session that lack provenance:

```bash
rivet stamp all --missing-provenance \
  --created-by ai-assisted \
  --model claude-sonnet-4-6
```

To audit provenance on the stored artifacts:

```bash
rivet audit
```

Note: `rivet stamp` requires an artifact ID (or `all`) and optionally a
`--session-id`. If a formal `ai-session` artifact is required for full
provenance tracing, create one in `artifacts/` before running `rivet stamp`,
linking it via `produced-by` to the artifacts it authored. The stamp command
alone (without an `ai-session` artifact) records model and session metadata
in the artifact YAML but does not create an `ai-session` record.

Provenance stamping for AFD-001 and this runbook was deferred from the initial
setup because creating an honest `ai-session` artifact would require information
(session ID, commit SHA) only available after the commit. Run `rivet stamp AFD-001`
after the initial commit to add provenance metadata.
