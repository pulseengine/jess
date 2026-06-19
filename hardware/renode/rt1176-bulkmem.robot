*** Settings ***
Suite Setup       Setup
Suite Teardown    Teardown
Resource          ${RENODEKEYWORDS}

# Hermetic RT1176 verification of synth's bulk-memory OOB trap routing (synth#374 /
# AFD-026). A wasm bulk-mem OOB access lowers to an inline UDF; with USGFAULTENA
# unset it escalates to HardFault; the self-contained synth ELF's vector table must
# route both slot 3 (HardFault) and slot 6 (UsageFault) to Trap_Handler. This is the
# one path synth's unicorn differential can't see. PC-based oracle: after a bounded
# run, the OOB image parks in Trap_Handler; the in-bounds image parks at the
# Reset_Handler post-call spin (NOT Trap_Handler).

*** Test Cases ***
OOB bulk-memory copy routes the fault to Trap_Handler
    Execute Command           mach create "rt1176-bulkmem-oob"
    Execute Command           machine LoadPlatformDescription @${CURDIR}/pixhawk6xrt.repl
    Execute Command           sysbus LoadELF @${CURDIR}/bulkmem/oob.elf
    ${trap}=                  Execute Command  sysbus GetSymbolAddress "Trap_Handler"
    Execute Command           emulation RunFor "0.02"
    ${pc}=                    Execute Command  sysbus.cpu PC
    Should Be Equal As Integers    ${pc}    ${trap}

In-bounds bulk-memory fill returns without trapping
    Execute Command           mach create "rt1176-bulkmem-ok"
    Execute Command           machine LoadPlatformDescription @${CURDIR}/pixhawk6xrt.repl
    Execute Command           sysbus LoadELF @${CURDIR}/bulkmem/ok.elf
    ${trap}=                  Execute Command  sysbus GetSymbolAddress "Trap_Handler"
    Execute Command           emulation RunFor "0.02"
    ${pc}=                    Execute Command  sysbus.cpu PC
    Should Not Be Equal As Integers    ${pc}    ${trap}
