# jess — Traceability & V&V Compliance Report

_Generated from the rivet artifact trace by `tools/compliance/gen.sh`._
_This is the regenerable source; the CI `rivet coverage --fail-under` step is the enforcement gate._

## Traceability coverage (`rivet coverage`)

```
Traceability Coverage Report

  Rule                           Source Type           Covered    Total        %
  --------------------------------------------------------------------------------
  requirement-coverage           requirement                14       23    60.9%
  requirement-verification       requirement                 9       23    39.1%
  decision-justification         design-decision            23       23   100.0%
  hazard-has-loss                hazard                     11       11   100.0%
  constraint-has-hazard          system-constraint          11       11   100.0%
  uca-has-hazard                 uca                        21       21   100.0%
  uca-has-controller             uca                        21       21   100.0%
  controller-constraint-has-uca  controller-constraint       16       16   100.0%
  hazard-has-constraint          hazard                     11       11   100.0%
  uca-has-controller-constraint  uca                        16       21    76.2%
  sec-hazard-has-loss            sec-hazard                  3        3   100.0%
  sec-constraint-has-hazard      sec-constraint              3        3   100.0%
  sec-uca-has-hazard             sec-uca                     1        1   100.0%
  sec-hazard-has-constraint      sec-hazard                  3        3   100.0%
  stkh-req-has-feat-req          stkh-req                    0        0   100.0%
  feat-req-derives-from-stkh     feat-req                    0        0   100.0%
  feat-req-has-comp-req          feat-req                    0        0   100.0%
  comp-req-derives-from-feat     comp-req                    0        0   100.0%
  comp-req-has-design            comp-req                    0        0   100.0%
  feat-has-comp                  feat                        0        0   100.0%
  comp-realizes-feat             comp                        0        0   100.0%
  test-spec-verifies-req         test-spec                   0       14     0.0%
  feat-req-has-verification      feat-req                    0        0   100.0%
  comp-req-has-verification      comp-req                    0        0   100.0%
  mod-belongs-to-comp            mod                         0        0   100.0%
  fmea-has-mitigation            fmea-entry                  0        0   100.0%
  dfa-has-mitigation             dfa-entry                   0        0   100.0%
  verdict-has-exec               test-verdict                0        0   100.0%
  verdict-fulfils-spec           test-verdict                0        0   100.0%
  goal-has-support               safety-goal                 5        9    55.6%
  strategy-decomposes-goal       safety-strategy             1        1   100.0%
  solution-supports-goal         safety-solution             4        4   100.0%
  goal-has-context               safety-goal                 1        9    11.1%
  release-has-attestation        release-artifact            0        0   100.0%
  vulnerability-has-affected-component vulnerability               0        0   100.0%
  stpa-hazards-have-safety-goals hazard                      9       11    81.8%
  stpa-losses-have-safety-goals  loss                        3        8    37.5%
  stpa-constraints-provide-evidence system-constraint           0       11     0.0%
  constraint-has-requirement     system-constraint           0       11     0.0%
  controller-constraint-has-requirement controller-constraint        0       16     0.0%
  --------------------------------------------------------------------------------
  Overall (weighted)                                      65.3%
  V-closure: requirement (all 2 rules)                    26.1%  [6/23]
  V-closure: hazard (all 3 rules)                         81.8%  [9/11]
  V-closure: system-constraint (all 3 rules)               0.0%  [0/11]
  V-closure: uca (all 3 rules)                            76.2%  [16/21]
  V-closure: controller-constraint (all 2 rules)           0.0%  [0/16]
  V-closure: sec-hazard (all 2 rules)                    100.0%  [3/3]
  V-closure: feat-req (all 3 rules)                      100.0%  [0/0]
  V-closure: comp-req (all 3 rules)                      100.0%  [0/0]
  V-closure: test-verdict (all 2 rules)                  100.0%  [0/0]
  V-closure: safety-goal (all 2 rules)                    11.1%  [1/9]

Uncovered artifacts:
  requirement-coverage (requirement):
    REQ-PIX-003
    REQ-PIX-004
    REQ-PIX-006
    REQ-PIX-008
    REQ-PIX-010
    REQ-PIX-011
    REQ-PIX-014
    REQ-PIX-018
    REQ-PIX-020
  requirement-verification (requirement):
    REQ-001
    REQ-002
    REQ-003
    REQ-PIX-002
    REQ-PIX-003
    REQ-PIX-004
    REQ-PIX-006
    REQ-PIX-008
    REQ-PIX-011
    REQ-PIX-012
    REQ-PIX-015
    REQ-PIX-019
    REQ-PIX-020
    REQ-PIX-021
  uca-has-controller-constraint (uca):
    U-001
    U-002
    gale:U-11
    gale:U-12
    gale:U-13
  test-spec-verifies-req (test-spec):
    TEST-PIX-001
    TEST-META-001
    TEST-PIX-010
    TEST-PIX-014
    TEST-PIX-013
    TEST-PIX-005
    TEST-PIX-016
    TEST-PIX-017
    TEST-PIX-018
    TEST-PIX-019
    TEST-PIX-020
    TEST-PIX-021
    TEST-PIX-022
    TEST-PIX-023
  goal-has-support (safety-goal):
    SG-001
    SG-002
    SG-003
    gale:SG-MEAS-001
  goal-has-context (safety-goal):
    SG-001
    SG-002
    SG-003
    gale:SG-MEAS-001
    gale:G-2
    gale:G-3
    gale:G-4
    gale:G-5
  stpa-hazards-have-safety-goals (hazard):
    H-002
    H-003
  stpa-losses-have-safety-goals (loss):
    L-001
    L-002
    L-003
    L-004
    L-005
  stpa-constraints-provide-evidence (system-constraint):
    SC-001
    SC-002
    SC-003
    SC-004
    SC-005
    gale:SC-1
    gale:SC-2
    gale:SC-3
    gale:SC-4
    gale:SC-5
    gale:SC-6
  constraint-has-requirement (system-constraint):
    SC-001
    SC-002
    SC-003
    SC-004
    SC-005
    gale:SC-1
    gale:SC-2
    gale:SC-3
    gale:SC-4
    gale:SC-5
    gale:SC-6
  controller-constraint-has-requirement (controller-constraint):
    gale:CC-1
    gale:CC-2
    gale:CC-3
    gale:CC-4
    gale:CC-5
    gale:CC-6
    gale:CC-7
    gale:CC-8
    gale:CC-9
    gale:CC-10
    gale:CC-11
    gale:CC-12
    gale:CC-13
    gale:CC-14
    gale:CC-15
    gale:CC-16
```

## CI verification gates (the right side of the V, per push to main)

| gate | what it proves | evidence |
|------|----------------|----------|
| rivet validate | the artifact spine is well-formed + coverage floor | this report |
| spar model | the AADL parses/instantiates; inter-core WIT is spar-derived | TEST-PIX-023 |
| mav_bench | MAVLink CRC decode over a committed 6X-RT sample | REQ-PIX-010 |
| Renode RT1176 smoke | the RT1176 model boots to the LPUART banner (+ synth #374/#507 oracles) | REQ-PIX-005, TEST-PIX-013/020 |
| scry sound-analysis | DO-333 sound abstract interpretation on the fused falcon core (0 unsound-fallback) | REQ-PIX-018, TEST-PIX-022 |

## Verification legs (DO-178C / DO-333 posture)

- **Structural analysis (DO-333):** scry sound abstract interpretation — GREEN, wired (TEST-PIX-022).
- **Structural coverage (witness MC/DC):** the harness-bridge follow-on remains (REQ-PIX-018 leg a).
- **Sound static + safety case:** STPA / STPA-sec / safety-goal layer (100% decision-justification, hazard, UCA coverage above).

_On-target requirement verification is legitimately incomplete (requirement-verification ~39%)
because the v0.7.0 on-target requirements are gated on the external synth poles (#369 hard-float,
#275/#676 dispatch) or the physical board — not on a jess process gap (see FEATURE-010, accepted)._
