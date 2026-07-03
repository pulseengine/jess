*** Settings ***
Resource          ${RENODEKEYWORDS}

# Hermetic Cortex-M3 runtime gate for synth's call_indirect on the self-contained
# --cortex-m path (AFD-008 / synth#275). ci_self.elf = `synth compile ci_self.wat
# --cortex-m -t cortex-m3` — an entry that call_indirects table[selector] (selector from
# linmem mem[100]) over 3 funcs returning 100/200/300, storing the result to mem[0].
# CORRECT dispatch: selector=1 -> f1 -> mem[0]=200 (0xC8). The synth#275/AFD-008 bug on
# the self-contained path emits NO funcref table (.rodata absent) and degrades to
# selector-passthrough -> mem[0]=selector=1. (The --relocatable path lowers it correctly.)
#
# RED until synth emits the funcref table on the self-contained path (or falcon moves to
# the --relocatable TCB-link, DD-018). Pattern mirrors TEST-PIX-020 (synth#507 br_table).
# NOT wired into CI while RED. Linmem base 0x20000100; ELF + literals are a matched pair.

*** Test Cases ***
call_indirect dispatches to the selected table entry (not selector-passthrough)
    Execute Command           mach create "ci-275"
    Execute Command           machine LoadPlatformDescription @${CURDIR}/m3.repl
    Execute Command           sysbus LoadELF @${CURDIR}/ci_self.elf
    Execute Command           sysbus WriteDoubleWord 0x20000164 0x1
    Execute Command           emulation RunFor "0.02"
    ${m0}=                    Execute Command  sysbus ReadDoubleWord 0x20000100
    # selector=1 must dispatch f1 -> 200 (0xC8); the #275 bug yields 1 (selector-passthrough)
    Should Be Equal As Integers    ${m0}    0xC8
