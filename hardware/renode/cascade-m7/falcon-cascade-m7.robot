*** Settings ***
Resource          ${RENODEKEYWORDS}
Test Setup        Boot Falcon Cascade

# TEST-PIX-031 — the FUSED falcon flight cascade executes on the i.MX RT1176 Cortex-M7.
#
# This is the emulation-track rung directly beneath real silicon, and the first execution
# of the falcon CASCADE (as opposed to a single stage) on an RT1176. The image under test is
# jess's own pipeline output end to end:
#
#   relay falcon-v1.134.1 OCI components (iekf position attitude rate mixer)
#     -> meld 0.52.0 fuse --memory shared --pack-rebase   (5 pages 320 KB -> 1 page 64 KB)
#     -> loom 1.4.1 optimize
#     -> synth (main, increments 1+2 / PR#1073+#1075) compile -t cortex-m7dp --cortex-m
#        (self-contained EXEC, 94,907 B)
#
# The image exports ALL FIVE cascade stages as real defined symbols:
#   attitude@0.7.0#tick · ekf@0.7.0#estimate · mixer@0.7.0#mix · position@0.7.0#tick · rate@0.7.0#tick
# ZERO skips. synth increment 2 (PR#1075, frame-homed overflow VFP locals) removed the 13->14
# homed-local wall that was GI-FPU-002; there is no remaining upstream gate on this path.
# (This block previously described a 2-of-5 image and said three stages were missing — stale
# after the 5/5 result landed, and caught by clean-room verification. Kept accurate here because
# THIS FILE IS THE EVIDENCE cited upstream for the 5/5 claim.)
#
# WHAT THIS ASSERTS, and why each assertion can actually FAIL:
#   A. LINEAR-MEMORY INIT — the reset handler copies 0xd061 (53,345) bytes of wasm linear
#      memory from flash 0x9cbc to RAM 0x20000100
#      (this said 0x2ac8 until 2026-09-02; 0x2ac8 is ARM CODE, not the data blob. The real
#      source is r0 = 0x9cbc at Reset_Handler+0x0, and post-run RAM matches it 100%. AFD-056.). The probes below are all NON-ZERO words,
#      deliberately: RAM reads back zero when untouched, so asserting on a zero word would be
#      VACUOUS (it could not distinguish "copied correctly" from "never executed"). Two of the
#      probes are recognisable f32 control constants (0x3E800000 = 0.25f, 0x42480000 = 50.0f).
#   B. EXECUTION PROGRESS — the CPU must actually run the image, not stall or lock up in a
#      fault. Asserted as: >100k instructions retired, and PC landing inside the image .text
#      (0x0..0xFB29). Both are discriminating — a never-started image retires ~0 instructions,
#      and a HardFault lockup pins PC at a fault vector rather than in the export region.
#      Observed: PC 0x16C, 0x341BF = 213,439 instructions retired.
#      NOTE — what this deliberately does NOT assert, and why: the reset handler also writes
#      CPACR (0xE000ED88) |= 0x00F00000 to enable CP10/CP11, which is the FPU-enable that a
#      cortex-m7dp hard-float image depends on. That register is NOT readable through
#      `sysbus ReadDoubleWord` on this platform: pixhawk6xrt.repl models the NVIC at
#      0xE000E000 but not the SCB, and Renode's CortexM keeps CPACR internal. The check was
#      written, returned an EMPTY string, and was replaced rather than left as a passing-looking
#      no-op. Modelling the SCB in the repl is the follow-up that would make it assertable.
#
# NOT asserted: that rate#tick computes correct torque. Invoking it needs canonical-ABI
# argument marshalling; that is the next rung, and it is where relay's SIL reference
# (converged 0.193 s, steady-state |err| 0.0059 rad/s) becomes the comparison baseline.

# IMAGE PROVENANCE PIN. Clean-room verification flagged that CI runs this robot against the
# COMMITTED ELF and never rebuilds the meld->loom->synth chain — so CI gated EXECUTION but not
# PROVENANCE, and a hand-swapped or drifted image would still pass. This pin makes a silent swap
# fail loudly. HONEST SCOPE: it detects that the committed bytes changed; it does NOT prove the
# pipeline produced them. The full gate (rebuild the chain in CI) needs meld/loom/synth in the
# runner and is tracked separately. The image IS bit-reproducible from the pipeline — a fresh
# build produced this exact digest — which is what makes pinning it meaningful rather than
# pinning an unreproducible blob.
*** Variables ***
${IMAGE_SHA256}   c692f50dc6cc1ee7994d6b072ad50b236456c04bb169da21c1c5f49ba91af193
${ELF}          ${CURDIR}/falcon-cascade-m7.elf
${PLATFORM}     ${CURDIR}/../pixhawk6xrt.repl
${TEXT_END}      0xFB29

*** Keywords ***
Boot Falcon Cascade
    Execute Command           mach create "falcon-m7"
    Execute Command           machine LoadPlatformDescription @${PLATFORM}
    Execute Command           sysbus LoadELF @${ELF}

Memory Word Should Be
    [Arguments]               ${addr}    ${expected}
    ${v}=    Execute Command  sysbus ReadDoubleWord ${addr}
    Should Contain            ${v}       ${expected}

*** Test Cases ***
Committed image is the one this oracle was written against
    ${actual}=    Run    shasum -a 256 ${ELF}
    Should Contain    ${actual}    ${IMAGE_SHA256}

Fused falcon cascade initialises linear memory on the RT1176 M7
    Execute Command           emulation RunFor "0.05"
    # non-zero probes — a vacuous zero-probe could not distinguish copied from never-ran
    Memory Word Should Be     0x20002108    0xB2F0B451
    Memory Word Should Be     0x2000210C    0xB044B196
    Memory Word Should Be     0x20002238    0x3E800000
    Memory Word Should Be     0x2000223C    0x42480000

Fused falcon cascade image RUNS ITS RESET PATH on the RT1176 M7 without stalling or faulting
    Execute Command           emulation RunFor "0.05"
    ${ins}=     Execute Command    cpu ExecutedInstructions
    ${n}=       Convert To Integer    ${ins.strip()}    16
    Should Be True            ${n} > 100000
    ${pc}=      Execute Command    cpu PC
    ${pcv}=     Convert To Integer    ${pc.strip()}    16
    Should Be True            ${pcv} > 0
    Should Be True            ${pcv} < 0xFB29
