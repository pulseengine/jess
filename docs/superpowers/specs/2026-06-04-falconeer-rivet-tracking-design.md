# falconeer — rivet tracking spine (design)

Date: 2026-06-04
Status: approved (brainstorming)

> **This doc is deliberately thin.** The substance lives in **rivet artifacts**
> (evidence as code), not here. This records only the decisions, their rationale,
> and the order in which the artifacts get built. Anything that can be a rivet
> artifact *is* one — including the standard-anchor decision (a `design-decision`).

## What falconeer is

The physical / hardware-integration project that takes **falcon** (the drone
software, built through the PulseEngine wasm→embedded pipeline) onto hardware,
in three phases, while running a **release-watch feedback loop** that pushes
findings back to each upstream component owner.

- **Pipeline producing falcon:** loom (optimize) → meld (fuse) → synth (wasm→ARM
  Cortex-M) → kiln (no_std runtime) → on gale (verified RTOS primitives).
- **Test target (P1):** STM32F4 / Renode + QEMU — the same hardware gale's
  `benches/flight_control` uses (`flight_stm32f4.robot`).
- **relay:** provides the simulation falcon is tested against in P1.

## Scope of THIS spec

The **rivet tracking spine** only: schema set, artifact taxonomy, the phased
roadmap as artifacts, and the release-watch / supplier feedback loop wired on
native rivet features. **Out of scope** (separate next spec, tracked here as a
`design-decision`): the HIL build-flash mechanics — how falcon is actually
compiled through the pipeline and flashed to the STM32F4 target.

## Decisions

1. **Tooling:** rivet **v0.15.0** (installed from the verified GitHub release
   prebuilt; the local repo checkout was stale at `v0.4.3-85`).
2. **Posture:** safety-forward from day one.
3. **Standard anchor:** STPA as the methodology spine + **ISO 26262** (ASIL)
   now — implemented with the **`score`** schema (Eclipse SCORE metamodel:
   ISO 26262 V-model, FMEA, DFA); reuses gale's existing STPA flight-control
   controllers and ASIL-D framing. **DO-178C preset deferred to Phase 3**
   (airborne; `rivet init --preset do-178c` exists). Recorded as a
   `design-decision` artifact so the rationale is traceable and revisable.
4. **Two cross-repo mechanisms, chosen per link** (per `rivet docs cross-repo`):
   - `externals:` in `rivet.yaml` — for upstream components that are themselves
     rivet projects. `rivet sync` clones to `.rivet/repos/`, `rivet lock` pins
     exact SHAs, and artifacts cross-link with `prefix:ID` (e.g. reuse gale's
     hazards as `gale:H-1`). This is the navigable "work back to the owner" graph.
   - `external-anchor` + `cited-source` — sha256-pinned, for non-rivet sources
     (relay's sim, a delivered compliance PDF). `rivet supplier pull` + `check`.
5. **Loop on native rivet, not bespoke scripts:** the two mechanisms above +
   `ai-found-defect` + `stamp`/`audit` (findings with provenance);
   `snapshot`/`impact`/`diff` (release deltas); `import-results`
   (HIL junit/reqif → verification). Ingestion point: the ecosystem-wide
   `{name}-v{version}-compliance-report.tar.gz` release asset (per `reports.toml`).

## Schema set (`rivet.yaml`)

`common, dev, research, stpa, score, safety-case, supply-chain`
(+ bridges that auto-load when both sides are present: stpa↔dev,
safety-case↔stpa, supply-chain↔dev). `score` is rivet's ISO 26262 schema.
`external-anchor`/`ai-found-defect`/`ai-session` are available from `common`.

## Artifact taxonomy (`artifacts/`)

| File / group | Type(s) | Purpose |
|---|---|---|
| `roadmap.yaml` | feature | The 3 phases (P1 HIL-vs-relay → P2 real drone HW → P3 flying drone), each a `feature` with a `phase` field |
| `requirements.yaml` | requirement | falconeer's own integration/system requirements |
| `design-decisions.yaml` | design-decision | Standard anchor; "HIL mechanics = separate spec"; loop design |
| `stpa/` | stpa types | Control structure, hazards, UCAs, loss scenarios (ref gale flight-control) |
| `safety-goals.yaml` | score types | ISO 26262 safety goals + ASIL, derived from hazards |
| `[externals]` (in `rivet.yaml`) | — | The upstream **rivet** repos, cross-linked via `prefix:ID`, pinned by `rivet lock` |
| `external-anchor`s | external-anchor | Supplier boundary for **non-rivet** sources (relay sim, delivered docs) |
| `findings.yaml` | ai-found-defect / defect | Loop findings → linked to supplier anchor + affected req/test + upstream issue URL |
| `results/` | verification (via `import-results`) | HIL bench output (Renode/QEMU junit) linked to requirements |

## Upstream components watched (suppliers)

gale, synth, loom, meld, kiln, rivet, sigil — each an `external-anchor`.
(spar, zephyr, bootloader candidates for later; not in the initial set.)

## Release-watch feedback loop (runbook)

1. Maintain `[externals]`; `rivet sync` + `rivet lock` → pinned baseline.
2. New release/tag (or `main` commit for repos without releases, e.g. gale):
   pull `compliance-report.tar.gz`; `rivet snapshot`/`impact`/`diff` for deltas.
3. Exercise via HIL bench; `rivet import-results`.
4. Log optimization/error as a finding → linked to supplier anchor + req/test.
5. Feed back: open upstream `gh` issue; link URL into finding; track
   open → reported → fixed-in vX → verified.
6. `rivet baseline verify` + `rivet supplier check`; re-pin on adoption.
7. Automation: documented runbook now; later a scheduled `/loop` or cron per component.

## Provenance

AI-authored artifacts stamped via `rivet stamp` / `ai-session` / `audit`
(ISO 26262-8 §11.4.5.4 tool-error-detection alignment).

## Build order (for the implementation plan)

1. `rivet.yaml`: add schema set + `[externals]` for the 7 components.
2. Verify schemas load (`rivet schema list`); regenerate `AGENTS.md`.
3. Seed `design-decisions.yaml` (incl. standard anchor) + `roadmap.yaml`.
4. Seed integration `requirements.yaml` + STPA skeleton + `safety-goals.yaml`.
5. Create `external-anchor`s; `rivet sync` + `rivet lock` baseline.
6. `findings.yaml` scaffold + one worked example from a current component delta.
7. `rivet validate` clean; commit.
