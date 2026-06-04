---
title: "jess roadmap — 0.1.0 to 0.10.0 (Phase 1)"
---

# jess roadmap: 0.1.0 → 0.10.0

> Authoritative source is the rivet artifacts (`rivet list --type feature`). This
> doc is the human-readable narrative + exit criteria. Versions 0.1–0.10 realize
> **Phase 1** (HIL of falcon against relay's simulation on gale's STM32F4
> hardware). Phase 2 (real drone hardware) is the 0.11+/0.2x line; Phase 3
> (flight) heads toward 1.0.

**Design principle:** every minor version is independently demonstrable — it
"works" on its own — and each closes a concrete gap found during bootstrapping
(loom optimizer bugs, STM32H743-vs-F4 board mismatch, pipeline/gale publish no
compliance reports, stale kiln v0.2.0, `synth_compile` disabled in relay's
`BUILD.bazel`).

**Proven during bootstrapping (pre-0.1.0):** with prebuilt CLIs, the real
`falcon-flight-v1.26.wasm` runs in wasmtime (stabilization 0.0234 rad < 0.1,
position-hold 0.132 m < 0.6 — PASS) and `synth compile --cortex-m` produces a
valid ARM Cortex-M ELF. `loom optimize` ran but produced invalid modules on two
of falcon's four inner modules (safe fallback) — tracked as a finding.

| Ver | Theme | Exit criteria |
|-----|-------|---------------|
| 0.1.0 | Reproducible forward chain (SIL + compile) | One `jess build`: fetch verified `falcon-v*.wasm` → wasmtime SIL gate → meld → loom → synth → Cortex-M ELF; evidence via `rivet import-results`. |
| 0.2.0 | Emulated bring-up on STM32F4 | Install Renode + arm-none-eabi-gcc; falcon firmware boots on emulated `stm32f4_disco`; an exported control fn executes. |
| 0.3.0 | HIL flight bench + gated metrics | Adapt gale's `flight_control` bench to falcon; CSV metrics → `analyze.py` gates vs relay-sim baseline. Closes REQ-002. |
| 0.4.0 | Supply-chain & provenance | Verify sigil/cosign signatures; ingest SBOM + relay `rivet-snapshot`; supply-chain artifacts per build. |
| 0.5.0 | Full dependency graph pinned | relay + meld/synth/kiln + critical `rules_*` as externals/anchors; baseline pinned; unresolved-graph blockers triaged. Closes REQ-003. |
| 0.6.0 | Release-watch automation v1 | Scheduled poll of upstreams → rebuild + re-HIL + `snapshot`/`impact`/`diff` → auto findings. |
| 0.7.0 | Upstream feedback loop closed | Auto-file `gh` issues for findings; track open→reported→fixed→verified; first loom-bug issue filed. |
| 0.8.0 | Safety case (STPA + ISO 26262) | Full control structure, UCAs, ASIL goals, FMEA/DFA cross-linked to gale/relay; coverage gates. |
| 0.9.0 | CI + hermetic build + own compliance report | jess GitHub Actions runs chain+HIL per falcon release; hermetic Bazel build; publish jess `compliance-report.tar.gz`. |
| 0.10.0 | Phase-1 complete + DO-178C bridge readiness | Any `falcon-v*` auto-built, HIL-tested on STM32F4, provenance-verified, findings fed back; DO-178C bridge scaffolding. Phase 1 done. |
