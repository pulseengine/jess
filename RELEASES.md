# jess releases

The release plan lives in the rivet trace (`release:` field; see DD-021). A release is
cut only when every requirement in its scope is `verified`/`accepted` with the V closed
(`rivet validate` + the V-closure query in `tools/rivet/snapshot.sh`). Each entry carries
a **falsification statement** — the observation that would prove the milestone's behavior
wrong — per the release-execution method.

## v0.6.0 — RT1176 hermetic emulation + MAVLink bench

The first tagged engineering milestone: jess can emulate the Pixhawk 6X-RT (i.MX RT1176)
M7 hermetically and decode real MAVLink off it, both gated in CI — the foundation the
on-target bring-up (v0.7.0+) builds on.

**Scope (V-closed, both `accepted`):**
- **REQ-PIX-005** — the hand-authored RT1176 Renode platform (`hardware/renode/pixhawk6xrt.repl`)
  boots bring-up firmware to the LPUART1 banner. Verified by **TEST-PIX-005**. The same
  `renode-smoke` CI gate also runs the synth#374 OOB-trap oracle (**TEST-PIX-013**) and the
  synth#507 br_table oracle (**TEST-PIX-020**).
- **REQ-PIX-010** — the MAVLink bench decodes the committed 6X-RT sample with correct X.25
  CRC (`tools/bench/test_mav_bench.py`). Verified by **TEST-PIX-010**.

**CI gates green on the tagged commit:** rivet validate · spar model · mav_bench oracle · Renode RT1176 smoke.

**Falsification statement:** _v0.6.0 is falsified if, on the tagged commit, the RT1176
Renode platform faults or fails to reach the `JESS-RT1176 boot OK` banner, OR the MAVLink
bench miscomputes the X.25 CRC on the committed sample (wrong frame/heartbeat/attitude
decode), OR any of the four CI gates is not `success`._

**Deferred out of scope (logged, DD-021):** REQ-PIX-001 (falcon hard-float firmware) →
v0.7.0 — its `fpv5-d16 hard-float` claim cannot reach `verified` until synth#369 + #275 land.

## v0.7.3 — tool release: with-device 0.5.0 + the Pixhawk 6X-RT Renode model

**A tool release on the v0.7 line, like v0.7.1 and v0.7.2. It closes NO milestone scope.** The
`release:` scopes in rivet (v0.7.0 on-target bring-up, v0.8.0 PX4 HITL + persistence +
root-of-trust, ...) are unchanged by this tag, and v0.8.0 stays reserved for its milestone.

**Why now (AFD-146):** jess's last release, v0.7.2, shipped with-device **0.2.2**. Since then the
source moved to **0.5.0**, and that 0.5.0 runs on all three bench hosts. It had no tag and no
signed asset, so the bench ran a binary with no release provenance, and the varve layer
(correctly) still carried 0.2.2.

**What ships:**
- **with-device 0.5.0** for four targets, built and self-tested on a host that can execute each.
  Since 0.2.2:
  - 0.3.0: device names are BOARDS, not probe models, with alias → canonical lock resolution
    (AFD-123, #266). **Interface change:** a registry entry named after a probe now resolves
    through `aliases:`.
  - 0.5.0: an EACCES is no longer reported as CLAIMED (AFD-133, jess#280).
- **`jess-renode-rt1176-<v>.tar.gz`, NEW**: the hand-authored Pixhawk 6X-RT Renode platform with
  its self-asserting smoke check (jess#299). Apache-2.0. This is the first real-tag run of
  #302/#303's release steps.
- SHA256SUMS.txt (cosign-signed), a CycloneDX SBOM and SLSA build provenance, as in v0.7.2.

**Falsification statement:** _v0.7.3 is falsified if a published asset fails `shasum -c` or
`cosign verify-blob` against the published SHA256SUMS.txt; OR `with-device --version` from an
asset prints anything other than `with-device 0.5.0`; OR the unpacked
`jess-renode-rt1176` archive's `rt1176-smoke-check.resc` does not print
`SMOKE PASS: JESS-RT1176 boot OK` and exit 0 under Renode 1.16.1; OR with-device reports a
permission failure on the lockdir as CLAIMED._

## Planned (not yet cuttable)

| release | theme | gated on |
|---|---|---|
| v0.7.0 | on-target bring-up (REQ-PIX-001/002/003/004/006/007/008/011/012) | synth #369 / #275 / #503 |
| v0.8.0 | PX4 HITL + persistence + root-of-trust (REQ-PIX-014/015/019) | v0.7.0 foundation |
| v0.9.0 | gust/F100 + combined vehicle + witness/scry gates (REQ-PIX-009/017/018) | gale#65, hub#98 |
