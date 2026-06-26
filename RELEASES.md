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

## Planned (not yet cuttable)

| release | theme | gated on |
|---|---|---|
| v0.7.0 | on-target bring-up (REQ-PIX-001/002/003/004/006/007/008/011/012) | synth #369 / #275 / #503 |
| v0.8.0 | PX4 HITL + persistence + root-of-trust (REQ-PIX-014/015/019) | v0.7.0 foundation |
| v0.9.0 | gust/F100 + combined vehicle + witness/scry gates (REQ-PIX-009/017/018) | gale#65, hub#98 |
