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
#     -> loom 1.2.0 optimize
#     -> synth 0.55 compile -t cortex-m7dp --cortex-m     (self-contained EXEC, 65,452 B)
#
# The image exports pulseengine:falcon-cascade/{rate@0.7.0#tick, mixer@0.7.0#mix} as real
# defined symbols. Three functions remain skipped (all GI-FPU-002 VFP register exhaustion,
# synth#881) so iekf/position/attitude entry points are NOT in this image — that is expected
# and is the single remaining upstream gate.
#
# WHAT THIS ASSERTS, and why each assertion can actually FAIL:
#   A. LINEAR-MEMORY INIT — the reset handler copies 0xd061 (53,345) bytes of wasm linear
#      memory from flash 0x2ac8 to RAM 0x20000100. The probes below are all NON-ZERO words,
#      deliberately: RAM reads back zero when untouched, so asserting on a zero word would be
#      VACUOUS (it could not distinguish "copied correctly" from "never executed"). Two of the
#      probes are recognisable f32 control constants (0x3E800000 = 0.25f, 0x42480000 = 50.0f).
#   B. EXECUTION PROGRESS — the CPU must actually run the image, not stall or lock up in a
#      fault. Asserted as: >100k instructions retired, and PC landing inside the image .text
#      (0x0..0xFB29). Both are discriminating — a never-started image retires ~0 instructions,
#      and a HardFault lockup pins PC at a fault vector rather than in the export region.
#      Observed: PC 0x16C (immediately below mixer@0.7.0#mix at 0x178), 0x344A8 = 214,696
#      instructions retired.
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

*** Variables ***
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
Fused falcon cascade initialises linear memory on the RT1176 M7
    Execute Command           emulation RunFor "0.05"
    # non-zero probes — a vacuous zero-probe could not distinguish copied from never-ran
    Memory Word Should Be     0x20002108    0xB2F0B451
    Memory Word Should Be     0x2000210C    0xB044B196
    Memory Word Should Be     0x20002238    0x3E800000
    Memory Word Should Be     0x2000223C    0x42480000

Fused falcon cascade executes on the RT1176 M7 without stalling or faulting
    Execute Command           emulation RunFor "0.05"
    ${ins}=     Execute Command    cpu ExecutedInstructions
    ${n}=       Convert To Integer    ${ins.strip()}    16
    Should Be True            ${n} > 100000
    ${pc}=      Execute Command    cpu PC
    ${pcv}=     Convert To Integer    ${pc.strip()}    16
    Should Be True            ${pcv} > 0
    Should Be True            ${pcv} < 0xFB29
