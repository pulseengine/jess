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
#
# Addresses are fixed in the committed ELFs (synth main @39010ce, --safety-bounds
# software): Trap_Handler = 0x9E (spin), Reset_Handler post-call spin = 0x94.
# (Renode's GetSymbolAddress doesn't see synth's symtab, so we assert literals.)

*** Test Cases ***
OOB bulk-memory copy routes the fault to Trap_Handler
    Execute Command           mach create "rt1176-bulkmem-oob"
    Execute Command           machine LoadPlatformDescription @${CURDIR}/pixhawk6xrt.repl
    Execute Command           sysbus LoadELF @${CURDIR}/bulkmem/oob.elf
    Execute Command           emulation RunFor "0.02"
    ${pc}=                    Execute Command  sysbus.cpu PC
    Should Be Equal As Integers    ${pc}    0x9E

In-bounds bulk-memory fill returns without trapping
    Execute Command           mach create "rt1176-bulkmem-ok"
    Execute Command           machine LoadPlatformDescription @${CURDIR}/pixhawk6xrt.repl
    Execute Command           sysbus LoadELF @${CURDIR}/bulkmem/ok.elf
    Execute Command           emulation RunFor "0.02"
    ${pc}=                    Execute Command  sysbus.cpu PC
    Should Be Equal As Integers    ${pc}    0x94
