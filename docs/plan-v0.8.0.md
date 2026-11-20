---
id: DOC-002
title: jess v0.8.0 plan — the ladder reported per rung
type: doc
status: draft
---

# jess v0.8.0 plan

Work in progress, drafted 2026-11-19 against main `217114e`; nothing here is done or tagged. The substance lives in rivet:
- FEATURE-014, the release
- REQ-PIX-023 and REQ-PIX-024, the requirements
- TEST-PIX-038 to TEST-PIX-040, the tests
- DD-029, the rung definitions

This page states only the bets, their order and what would kill each one.

**Objective served:** north-star O1, "Runs on target". jess `pulls = ["O1"]`.

**Theme:** jess's ladder becomes a machine-readable result per target and version. Every rung is pass or fail, and a rung that did not run is a fail.

**What it does not claim:** O1 stays `unmeasured` until pulseengine.eu runs an indicator script over the file. jess supplies the first O1 input, not the O1 value. The synth half of O1 (reach, execution match, WCET bound) is not jess's to report; its slots in the file read "not reported by jess".

## How the plan was made

1. A planner pass produced five bets from:
   - the north star;
   - the rivet state;
   - the open issues;
   - the v0.7.3 notes;
   - the jess#313 needs list.
2. A second pass with fresh context saw only the north star and the draft. It checked each bet on three questions: does it move an indicator, can its criterion fail, is anything overclaimed?
3. The plan was revised from the checker's findings:
   - B1 is no longer called "the first measured O1 value".
   - The O2/O3 tags were removed.
   - The bets were reordered by dependency.
   - The five-stage bet was split into one step per variable.
   - Completion floors were added.
   - The tick-timing bet was cut.

## Bets, in execution order

| | bet | moves | acceptance (can fail) | kill |
|---|---|---|---|---|
| B1 | **Ladder result file.** A generator re-runs the existing judges over committed captures and writes `ladder.json`, signed on the release (REQ-PIX-023). | the first O1 input from jess | TEST-PIX-038 passes N of N in CI. It needs a pass-path set, a tampered set, a not-run set (giving fail with ran false), and refusals for an emulator origin, a sha mismatch, a stale version, an absent sentinel and an omitted rung. The output validates against a committed schema. | The generator cannot refuse emulator captures mechanically, so the file would be a typed claim. |
| B2 | **R0 repeatable on silicon** (TEST-PIX-039) | r0, the prerequisite for the hil rung | 60 load attempts in total. ≥10 of 20 complete per image, ≥3 completed runs judged per image, zero wrong words, oracle exit 0. A replacement control B is specified before any run. | Any wrong word stops the release. A completion rate under 50% means load-to-RAM is not a base for B4, and r0 is recorded as fail. |
| B3 | **Five of five stages on silicon** (TEST-PIX-040). Position and attitude are added at the current pin. Moving the falcon pin to v1.142.0 is a separate step, which closes AFD-152. | the cascade under test becomes the whole cascade | Each stage is bit-exact against wasmtime on silicon, with one attributive control per stage and the denominators stated. | A divergence ships as a fail and becomes a lowering finding. The "independent oracle" part is dropped if relay#376 does not land. |
| B4 | **Lockstep PIL step below hil** against the relay plant (REQ-PIX-024) | a PIL result reported under hil; the hil rung stays not run (ran false), per DD-029 | 2000 ticks and ≥3 runs. Motor words are bit-identical to wasmtime every tick. A perturbed-input control and a planted output difference are both caught. | (Fired 2026-11-20 as a hil bet: the owner ruled lockstep SWD is not hil; B4 continues as a PIL step.) A 2000-tick run does not fit one claim window. The relay plant cannot be stepped from outside its harness. |

Small items in the same release:
- `serves:` validation and its drift check in jess, once rivet ships the field.
- B1's silicon captures move out of the ignored `.scratch` into a tracked directory, bound to the ELF sha256.

Cut to a later release: on-target tick timing. It can only become an indicator as a cross-check against synth's WCET bound for the same ELF.

## Cross-repo dependencies

| repo | needed for | state |
|---|---|---|
| pulseengine.eu | an O1 indicator script that reads `ladder.json` | not shipped |
| relay | falcon-v1.142.0 | shipped 2026-11-12 |
| relay | relay#376 per-tick reference vectors | not shipped |
| relay | a plant that can be stepped from outside its harness | not verified |
| synth, meld, loom | current pins | shipped |

## Owner rulings (2026-11-20)

- **The v0.8.0 number** goes to this release. The safety case (FEATURE-011) moves to v0.9.0; FEATURE-012 and FEATURE-013 shift to v0.10.0 and v0.11.0.
- **DD-029, accepted:** lockstep SWD injection does not fill the hil rung. It is reported as a PIL step below hil.
- B2-B4 are worked before the tag.

## Owner-gated

- **O2:** is jess a consumer repository for O2?
- Any required-check change, the tag, and every flash write. The plan uses load-to-RAM only.
