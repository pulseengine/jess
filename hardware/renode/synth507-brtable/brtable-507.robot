*** Settings ***
Resource          ${RENODEKEYWORDS}

# Hermetic Cortex-M3 runtime oracle for synth's br_table lowering (AFD-032 / synth#507).
# brt_self.elf (synth compile --cortex-m, the optimized/non-relocatable path) runs a
# 4-arm br_table whose selector is loaded from linear memory (mem[100], set to 2 here
# so it cannot be const-folded). CORRECT lowering branches to case 2 only -> mem[8]=30,
# and mem[0] stays 0. The synth#507 bug elides the selector and runs ALL arms ->
# mem[0]=10, mem[4]=20, mem[8]=30, mem[12]=40.
#
# Discriminator = mem[0] @ 0x20000100 (linmem base): 0 = correct, 10 = miscompiled.
# This oracle is RED on the buggy optimized path and flips GREEN when synth#507 lands
# (the --relocatable path already passes). NOT wired into CI until the fix ships.
# Pattern mirrors TEST-PIX-013 (the Renode OOB oracle that gated synth#374).

*** Test Cases ***
br_table selector is honored (only the selected arm runs)
    Execute Command           mach create "brt-507"
    Execute Command           machine LoadPlatformDescription @${CURDIR}/m3.repl
    Execute Command           sysbus LoadELF @${CURDIR}/brt_self.elf
    # input: selector = 2 (loaded by the program from linmem mem[100] = 0x20000164)
    Execute Command           sysbus WriteDoubleWord 0x20000164 0x2
    Execute Command           emulation RunFor "0.02"
    ${m0}=                    Execute Command  sysbus ReadDoubleWord 0x20000100
    ${m8}=                    Execute Command  sysbus ReadDoubleWord 0x20000108
    # case-2 arm must run (mem[8]=30) and case-0 arm must NOT (mem[0]=0)
    Should Be Equal As Integers    ${m8}    0x1E
    Should Be Equal As Integers    ${m0}    0x0
