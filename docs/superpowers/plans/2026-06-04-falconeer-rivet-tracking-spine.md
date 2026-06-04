# falconeer rivet tracking spine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up falconeer's rivet tracking spine — schema set, the phased roadmap + integration requirements + standard-anchor decision + STPA/score safety artifacts, the upstream components as cross-repo externals/anchors, and a worked release-watch finding — all validating clean.

**Architecture:** Everything is a rivet artifact ("evidence as code"). Upstream rivet repos are declared as `[externals]` and cross-linked by `prefix:ID`; non-rivet sources are `external-anchor`s. The release-watch loop is native rivet (`sync`/`lock`/`snapshot`/`impact`/`supplier`/`import-results`), wrapped in a runbook.

**Tech Stack:** rivet 0.15.0 CLI, YAML artifacts, `gh` for upstream feedback.

**The oracle (our "tests"):** `rivet validate` (must end `Result: PASS`), `rivet schema list`, `rivet supplier check`, `rivet stats`. Each task ends by running the relevant oracle and committing.

**Spec:** `docs/superpowers/specs/2026-06-04-falconeer-rivet-tracking-design.md`

---

### Task 1: Schema set in `rivet.yaml`

**Files:**
- Modify: `rivet.yaml`

- [ ] **Step 1: Set the safety-forward schema list.** Replace the `schemas:` block so it reads exactly:

```yaml
project:
  name: falconeer
  version: "0.1.0"
  schemas:
    - common
    - dev
    - research
    - stpa
    - score
    - safety-case
    - supply-chain

sources:
  - path: artifacts
    format: generic-yaml

docs:
  - docs

results: results
```

- [ ] **Step 2: Verify schemas load and types appear.**

Run: `rivet schema list`
Expected: lists types from dev (requirement, design-decision, feature), stpa (losses…scenarios), score (ISO 26262 V-model/FMEA), safety-case (goal, strategy…), supply-chain (sbom-component, release-artifact…), plus common's external-anchor / ai-found-defect / ai-session. No error.

- [ ] **Step 3: Validate (existing template artifacts still pass).**

Run: `rivet validate`
Expected: `Result: PASS`. (REQ-001/FEAT-001 template artifacts remain valid.)

- [ ] **Step 4: Commit.**

```bash
git add rivet.yaml
git commit -m "feat(rivet): adopt safety-forward schema set (stpa, score, safety-case, supply-chain)"
```

---

### Task 2: Regenerate AGENTS.md / CLAUDE.md for the new schemas

**Files:**
- Modify: `AGENTS.md`, `CLAUDE.md`

- [ ] **Step 1: Regenerate from current project state**, preserving the existing CLAUDE.md additions.

Run: `rivet init --agents --migrate`
Expected: AGENTS.md reflects the new schema set and type counts; CLAUDE.md keeps its "Additional Claude Code settings" below a rivet-managed marker.

- [ ] **Step 2: Validate nothing broke.**

Run: `rivet validate`
Expected: `Result: PASS`

- [ ] **Step 3: Commit.**

```bash
git add AGENTS.md CLAUDE.md
git commit -m "docs(rivet): regenerate AGENTS.md for new schema set"
```

---

### Task 3: Replace the template requirement with the standard-anchor decision

**Files:**
- Modify: `artifacts/requirements.yaml` (remove template REQ-001/FEAT-001)
- Create: `artifacts/design-decisions.yaml`

- [ ] **Step 1: Remove the two template artifacts** from `artifacts/requirements.yaml` so the file is an empty `artifacts: []` (we re-seed real requirements in Task 5).

```yaml
artifacts: []
```

- [ ] **Step 2: Create the standard-anchor decision.**

Run:
```bash
rivet add -t design-decision \
  --title "Anchor safety case to STPA + ISO 26262 (score), defer DO-178C to Phase 3" \
  --status accepted \
  --tags safety,standards \
  --field rationale="Toolchain is ISO-26262-aligned today (gale is ASIL-D); the drone is the demonstrator. STPA is the methodology spine; the score schema carries ISO 26262 V-model/FMEA. DO-178C (preset) is added when the airborne Phase 3 needs it." \
  --file artifacts/design-decisions.yaml
```
Expected: prints the new ID (e.g. `DD-001`). If `--field rationale` is rejected as unknown, re-run putting the rationale in `--description` instead, then `rivet schema show design-decision` to see allowed fields.

- [ ] **Step 3: Add the scope-boundary decision (HIL mechanics = separate spec).**

```bash
rivet add -t design-decision \
  --title "HIL build-flash mechanics are a separate Phase-1 spec" \
  --status accepted --tags scope \
  --description "How falcon is compiled through meld→loom→synth→kiln and flashed to STM32F4 is out of scope for the tracking spine; brainstormed as its own spec." \
  --file artifacts/design-decisions.yaml
```

- [ ] **Step 4: Validate.**

Run: `rivet validate`
Expected: `Result: PASS`

- [ ] **Step 5: Commit.**

```bash
git add artifacts/
git commit -m "feat(artifacts): record standard-anchor and scope design decisions"
```

---

### Task 4: Phased roadmap as `feature` artifacts

**Files:**
- Create: `artifacts/roadmap.yaml`

- [ ] **Step 1: Create the three phase features.**

```bash
rivet add -t feature --title "Phase 1 — HIL: falcon on STM32F4/Renode vs relay simulation" \
  --status draft --field phase=phase-1 --tags roadmap,hil --file artifacts/roadmap.yaml
rivet add -t feature --title "Phase 2 — falcon on real drone hardware (bench/tethered)" \
  --status draft --field phase=phase-2 --tags roadmap,hardware --file artifacts/roadmap.yaml
rivet add -t feature --title "Phase 3 — real flying drone (+ DO-178C bridge)" \
  --status draft --field phase=phase-3 --tags roadmap,airborne --file artifacts/roadmap.yaml
```
Expected: three IDs (FEAT-001..003). If `--field phase=` is rejected, run `rivet schema show feature` for the allowed field name and adjust.

- [ ] **Step 2: Validate.**

Run: `rivet validate`
Expected: `Result: PASS`

- [ ] **Step 3: Commit.**

```bash
git add artifacts/roadmap.yaml
git commit -m "feat(artifacts): add 3-phase roadmap features"
```

---

### Task 5: Integration/system requirements

**Files:**
- Modify: `artifacts/requirements.yaml`

- [ ] **Step 1: Seed falconeer's own integration requirements**, each linked to the phase it serves. Run (adjust phase target IDs to those printed in Task 4):

```bash
rivet add -t requirement --title "falcon firmware image boots on the STM32F4 Renode target" \
  --status draft --field priority=must --field category=functional \
  --link satisfies:FEAT-001 --file artifacts/requirements.yaml
rivet add -t requirement --title "HIL run reproduces relay-simulated flight scenarios within tolerance" \
  --status draft --field priority=must --field category=functional \
  --link satisfies:FEAT-001 --file artifacts/requirements.yaml
rivet add -t requirement --title "Each adopted upstream component release is pinned and traceable" \
  --status draft --field priority=must --field category="non-functional" \
  --link satisfies:FEAT-001 --file artifacts/requirements.yaml
```
Expected: three REQ IDs. If a `--field` key is rejected, run `rivet schema show requirement` and use the allowed keys.

- [ ] **Step 2: Validate (link targets resolve).**

Run: `rivet validate`
Expected: `Result: PASS`, zero broken-link diagnostics.

- [ ] **Step 3: Commit.**

```bash
git add artifacts/requirements.yaml
git commit -m "feat(artifacts): seed integration/system requirements"
```

---

### Task 6: Upstream components as cross-repo externals

**Files:**
- Modify: `rivet.yaml`
- Create: `rivet.lock` (generated)

- [ ] **Step 1: Determine which of the 7 siblings are rivet projects.**

Run: `for d in gale synth loom meld kiln rivet sigil; do printf "%s: " "$d"; test -f ../$d/rivet.yaml && echo "rivet project" || echo "NOT rivet"; done`
Expected: a rivet/not-rivet verdict per component. Rivet projects → `[externals]` (this task). Non-rivet → `external-anchor` (Task 7).

- [ ] **Step 2: Add an `externals:` block to `rivet.yaml`** for each component that IS a rivet project. Use the git URL and pin rivet itself to its release tag; others to `main` (gale has no releases). Include only the rivet-project ones from Step 1:

```yaml
externals:
  gale:   { git: https://github.com/pulseengine/gale,   ref: main,     prefix: gale }
  synth:  { git: https://github.com/pulseengine/synth,  ref: main,     prefix: synth }
  loom:   { git: https://github.com/pulseengine/loom,   ref: main,     prefix: loom }
  meld:   { git: https://github.com/pulseengine/meld,   ref: main,     prefix: meld }
  kiln:   { git: https://github.com/pulseengine/kiln,   ref: main,     prefix: kiln }
  rivet:  { git: https://github.com/pulseengine/rivet,  ref: v0.15.0,  prefix: rivet }
  sigil:  { git: https://github.com/pulseengine/sigil,  ref: main,     prefix: sigil }
```

- [ ] **Step 3: Fetch and pin the baseline.**

Run: `rivet sync && rivet lock`
Expected: repos cloned into `.rivet/repos/`; `rivet.lock` written with exact SHAs per external.

- [ ] **Step 4: Validate cross-repo (no broken externals/cycles).**

Run: `rivet validate`
Expected: `Result: PASS`. Resolves external prefixes; reports no circular deps / version conflicts.

- [ ] **Step 5: Commit (do NOT commit the `.rivet/repos/` cache).**

```bash
printf '.rivet/repos/\n.rivet/supplier-cache/\n' >> .gitignore
git add rivet.yaml rivet.lock .gitignore
git commit -m "feat(rivet): declare upstream components as pinned externals"
```

---

### Task 7: Non-rivet supplier boundaries (relay + compliance-report ingestion)

**Files:**
- Create: `artifacts/suppliers.yaml`

- [ ] **Step 1: Inspect the external-anchor schema** so fields are correct.

Run: `rivet schema show external-anchor`
Expected: shows fields (org/contract/received-status/cited-source etc.). Use the printed field names below.

- [ ] **Step 2: Create an `external-anchor` for relay** (non-rivet simulation supplier) and for any component from Task 6 Step 1 that was NOT a rivet project. Example for relay (replace field keys with those from Step 1):

```bash
rivet add -t external-anchor --title "relay flight simulation (supplier boundary)" \
  --status draft --tags supplier,simulation \
  --description "relay provides the simulation falcon is tested against in Phase 1; non-rivet source, content-hash pinned." \
  --file artifacts/suppliers.yaml
```

- [ ] **Step 3: Validate + check supplier coverage.**

Run: `rivet validate && rivet supplier check`
Expected: `Result: PASS`; supplier check prints the 3-state breakdown (satisfied / external-boundary / uncovered).

- [ ] **Step 4: Commit.**

```bash
git add artifacts/suppliers.yaml
git commit -m "feat(artifacts): add supplier-boundary external-anchors"
```

---

### Task 8: STPA skeleton + ISO 26262 safety goal, cross-linked to gale

**Files:**
- Create: `artifacts/stpa.yaml`, `artifacts/safety-goals.yaml`

- [ ] **Step 1: Inspect the relevant schema types** so required fields are right.

Run: `rivet schema show loss && rivet schema show hazard`
Expected: field lists for the stpa types (exact type slugs from `rivet schema list`; adjust if named e.g. `stpa-loss`).

- [ ] **Step 2: Add a minimal STPA chain** (one loss → one hazard). Use the type slugs and fields from Step 1:

```bash
rivet add -t loss --title "Loss of controlled flight leading to crash" \
  --status draft --tags stpa --file artifacts/stpa.yaml
# then add a hazard linked to that loss id (LOSS id from above):
rivet add -t hazard --title "Drone departs safe flight envelope" \
  --status draft --tags stpa --link "traces-to:<LOSS-ID>" --file artifacts/stpa.yaml
```

- [ ] **Step 3: Add an ISO 26262 (score) safety goal** derived from the hazard, and cross-link to gale's flight-control analysis via the `gale:` prefix (pick a real gale id from `rivet get --project ../gale ...` or `rivet list`):

```bash
rivet add -t safety-goal --title "Maintain safe flight envelope (ASIL TBD-from-HARA)" \
  --status draft --tags iso26262 \
  --link "derives-from:<HAZARD-ID>" \
  --file artifacts/safety-goals.yaml
```
Expected: IDs printed. If `safety-goal` is not the score slug, use the one from `rivet schema list` (score section).

- [ ] **Step 4: Validate (local + cross-repo links).**

Run: `rivet validate`
Expected: `Result: PASS`. Any `gale:ID` references resolve against `.rivet/repos/`.

- [ ] **Step 5: Commit.**

```bash
git add artifacts/stpa.yaml artifacts/safety-goals.yaml
git commit -m "feat(artifacts): STPA loss/hazard + ISO 26262 safety goal"
```

---

### Task 9: One worked release-watch finding + the runbook

**Files:**
- Create: `artifacts/findings.yaml`, `docs/release-watch-runbook.md`

- [ ] **Step 1: Produce a real delta against a pinned external.**

Run: `rivet impact --since HEAD~1` (and/or `rivet snapshot` per `rivet snapshot --help`)
Expected: prints what changed; confirms the impact/snapshot machinery works on this project.

- [ ] **Step 2: Record one finding as an `ai-found-defect`** linked to the upstream component, with status and (placeholder) upstream issue reference. Inspect fields first: `rivet schema show ai-found-defect`. Then:

```bash
rivet add -t ai-found-defect \
  --title "Example: optimization opportunity observed in <component> during HIL bring-up" \
  --status open --tags release-watch \
  --description "Worked example of the loop output. Replace with a real finding. Upstream issue: <gh-url-after-filing>." \
  --link "traces-to:rivet:REQ-001" \
  --file artifacts/findings.yaml
```
Expected: ID printed. (Use a real `prefix:ID` target that exists in the synced external; otherwise drop the `--link` and add it once a real target is known.)

- [ ] **Step 3: Write the release-watch runbook** capturing the loop steps (sync/lock → pull compliance-report → snapshot/impact → exercise HIL → import-results → log finding → `gh issue create` → link URL → track to closure → re-pin). Mirror §"Release-watch feedback loop" of the spec.

- [ ] **Step 4: Final full validate + stats.**

Run: `rivet validate && rivet stats`
Expected: `Result: PASS`; stats show the new artifact counts across types.

- [ ] **Step 5: Stamp AI-authored artifacts (provenance).**

Run: `rivet stamp --help` then stamp the artifacts created in this session per its usage.
Expected: artifacts carry AI-provenance metadata; `rivet validate` still `PASS`.

- [ ] **Step 6: Commit.**

```bash
git add artifacts/findings.yaml docs/release-watch-runbook.md
git commit -m "feat: worked release-watch finding + loop runbook"
```

---

## Self-review notes

- **Spec coverage:** schema set (T1), AGENTS regen (T2), standard-anchor + scope decisions (T3), roadmap (T4), requirements (T5), externals/pin (T6), supplier boundaries incl. relay (T7), STPA + ISO 26262 cross-linked to gale (T8), release-watch finding + runbook + provenance (T9). All spec sections mapped.
- **Schema-slug risk:** exact type slugs (loss/hazard/safety-goal/external-anchor field names) are confirmed in-task via `rivet schema show`/`rivet schema list` before use — this is intentional, since slugs come from rivet's bundled schemas, not from us.
- **Oracle every task:** every task ends on `rivet validate` (→ `Result: PASS`) and a commit.
