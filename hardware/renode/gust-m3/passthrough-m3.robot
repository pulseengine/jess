*** Settings ***
Resource          ${RENODEKEYWORDS}
Test Setup        Boot Gust Passthrough

# Hermetic Cortex-M3 (STM32F100 = the F100 gust failsafe core) execution gate for the
# gust byte-exact PASS-THROUGH (REQ-PIX-004 PART-P02 (a), TEST-PIX-028). This is the
# on-target rung above the host-level property oracle (TEST-PIX-027): the synth-compiled
# pass-through (passthrough_mem.elf, `synth compile --cortex-m -t cortex-m3`) runs on the
# emulated M3 and MUST forward the 4 per-motor commands BYTE-EXACT — no re-mix, no floors.
# The safety-critical case is the rank-3 rotor-out row with motors 0 AND 2 ZEROED: the
# zeros MUST survive un-re-mixed (a re-mix reintroduces the relay v1.114 parasitic moment).
#
# ABI: synth v0.58 self-contained, built --stack-layout low --stack-size 1024, so the stack
# is reserved at the BOTTOM of SRAM (SP init 0x20000400) and linear memory sits ABOVE it at
# 0x20000500. The pass-through reads the 4 inputs at +0..12 and writes the 4 outputs at
# +16..28. The ELF + these bases are a matched pair — rebuild both together (build.sh; the
# base is the movw/movt pair for fp in `entry`).
#
# THE PLATFORM IS NOW THE REAL PART'S GEOMETRY, NOT A GENEROUS ONE (AFD-088). m3.repl used
# to declare 256 KB of SRAM; a real STM32F100 has 8 KB, measured over SWD on the bench
# (DBGMCU_IDCODE 0x10016420, flash-size reg 0x0080 = 128 KB, existing firmware MSP
# 0x20002000). The previous image put its stack at 0x20020000 — outside physical SRAM — and
# passed anyway, because the emulator was more permissive than the hardware. It now runs in
# 8 KB, which is what makes 'on-target' mean something here.
# Test vectors are real rows from relay's fixture hardware/gust/fixtures/f100-passthrough-v1.csv.

*** Variables ***
${IN0}      0x20000500
${IN1}      0x20000504
${IN2}      0x20000508
${IN3}      0x2000050C
${OUT0}     0x20000510
${OUT1}     0x20000514
${OUT2}     0x20000518
${OUT3}     0x2000051C

*** Keywords ***
Boot Gust Passthrough
    Execute Command           mach create "gustm3"
    Execute Command           machine LoadPlatformDescription @${CURDIR}/m3.repl
    Execute Command           sysbus LoadELF @${CURDIR}/passthrough_mem.elf

Pass Through Row Is Byte Exact
    [Arguments]               ${m0}    ${m1}    ${m2}    ${m3}
    Execute Command           sysbus WriteDoubleWord ${IN0} ${m0}
    Execute Command           sysbus WriteDoubleWord ${IN1} ${m1}
    Execute Command           sysbus WriteDoubleWord ${IN2} ${m2}
    Execute Command           sysbus WriteDoubleWord ${IN3} ${m3}
    Execute Command           emulation RunFor "0.01"
    ${o0}=                    Execute Command  sysbus ReadDoubleWord ${OUT0}
    ${o1}=                    Execute Command  sysbus ReadDoubleWord ${OUT1}
    ${o2}=                    Execute Command  sysbus ReadDoubleWord ${OUT2}
    ${o3}=                    Execute Command  sysbus ReadDoubleWord ${OUT3}
    Should Be Equal As Integers    ${o0}    ${m0}    output motor 0 not byte-exact
    Should Be Equal As Integers    ${o1}    ${m1}    output motor 1 not byte-exact
    Should Be Equal As Integers    ${o2}    ${m2}    output motor 2 not byte-exact
    Should Be Equal As Integers    ${o3}    ${m3}    output motor 3 not byte-exact

*** Test Cases ***
Rotor-out asymmetric zeros survive un-re-mixed (motors 0 and 2 = 0)
    # relay fixture rotor_out row: m0=0, m2=0 — the PART-P02 (a) safety-critical case.
    Pass Through Row Is Byte Exact    0x00000000    0x3f3ccbcb    0x00000000    0x3f3ccbcb

Hover row is byte-exact
    Pass Through Row Is Byte Exact    0x3f266666    0x3f266666    0x3f266666    0x3f266666

Saturated row is byte-exact
    Pass Through Row Is Byte Exact    0x3ee77cd9    0x3ef38916    0x3eeb7bad    0x3edf8454
