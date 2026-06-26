*** Settings ***
Resource          ${RENODEKEYWORDS}

# Hermetic Cortex-M3 runtime gate for synth's br_table lowering (AFD-032 / synth#507).
# brt_self.elf (synth compile --cortex-m, the optimized/non-relocatable path) runs a
# 4-arm br_table whose selector is loaded from linear memory (mem[100], set to 2 here
# so it cannot be const-folded). CORRECT lowering branches to case 2 ONLY -> mem[8]=30,
# all other arms untouched (mem[0]=mem[4]=mem[12]=0). The (now fixed) synth#507 bug
# elided the selector and ran ALL arms -> mem[0]=10, mem[4]=20, mem[8]=30, mem[12]=40.
#
# RESOLVED in synth v0.17.0 (PR #508: "optimized path declines br_table to the direct
# selector"): this gate is now GREEN and guards against regression. Pattern mirrors
# TEST-PIX-013 (the Renode OOB oracle that gated synth#374).
#
# Linear-memory base for the committed ELF (synth 0.17.0) = 0x20000000, so
# mem[N] @ 0x20000000+N; selector mem[100] @ 0x20000064. The ELF + these literals are
# a matched pair — rebuild both together if the ELF is regenerated on a newer synth.

*** Test Cases ***
br_table selector is honored (only the selected arm runs)
    Execute Command           mach create "brt-507"
    Execute Command           machine LoadPlatformDescription @${CURDIR}/m3.repl
    Execute Command           sysbus LoadELF @${CURDIR}/brt_self.elf
    # input: selector = 2 (loaded by the program from linmem mem[100] = 0x20000064)
    Execute Command           sysbus WriteDoubleWord 0x20000064 0x2
    Execute Command           emulation RunFor "0.02"
    ${m0}=                    Execute Command  sysbus ReadDoubleWord 0x20000000
    ${m4}=                    Execute Command  sysbus ReadDoubleWord 0x20000004
    ${m8}=                    Execute Command  sysbus ReadDoubleWord 0x20000008
    ${m12}=                   Execute Command  sysbus ReadDoubleWord 0x2000000C
    # the selected arm (case 2) runs...
    Should Be Equal As Integers    ${m8}     0x1E
    # ...and NO other arm runs (the #507 regression would set these)
    Should Be Equal As Integers    ${m0}     0x0
    Should Be Equal As Integers    ${m4}     0x0
    Should Be Equal As Integers    ${m12}    0x0
