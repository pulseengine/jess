*** Settings ***
Resource          ${RENODEKEYWORDS}

# Hermetic inter-core NavState crossing oracle (REQ-PIX-007, TEST-PIX-030) on the
# dual-core RT1176 model. The 3-core partition's sole M7<->M4 crossing is the NavState
# message (16 x f32 = 64 B). This proves it crosses BYTE-EXACT over the shared-SRAM ring:
#   - cpu_m4 (estimator core) writes the 16-word NavState to SHMEM @0x20400000, then
#     publishes a READY flag @0x20400040 LAST (flag-last release order).
#   - cpu_m7 (flight core) spins on the flag (acquire), then copies the 16 words from
#     SHMEM to its own DTCM @0x20010000.
# The robot asserts every DTCM output word == the producer pattern 0x4E560000+i — so the
# NavState survived the M4 -> shared-SRAM -> M7 crossing bit-for-bit (no corruption, no
# partial read). This is the payload-fidelity half of REQ-PIX-007; the MU doorbell
# datapath is separately exercised by the vehicle multinode demo (TEST-PIX-019).
# ELFs are committed; rebuild both together via build.sh if addresses change.

*** Test Cases ***
NavState crosses M4 -> shared SRAM -> M7 byte-exact (16 x f32)
    Execute Command           mach create "rt1176"
    Execute Command           machine LoadPlatformDescription @${CURDIR}/../vehicle/rt1176-dualcore.repl
    Execute Command           sysbus LoadELF @${CURDIR}/nav_consumer_m7.elf cpu=cpu_m7
    Execute Command           sysbus LoadELF @${CURDIR}/nav_producer_m4.elf cpu=cpu_m4
    Execute Command           cpu_m7 VectorTableOffset 0x0
    Execute Command           cpu_m4 VectorTableOffset 0x20240000
    Execute Command           emulation RunFor "0.01"
    FOR    ${i}    IN RANGE    0    16
        ${addr}=    Evaluate    ${0x20010000} + ${i} * 4
        ${exp}=     Evaluate    ${0x4E560000} + ${i}
        ${got}=     Execute Command    sysbus ReadDoubleWord ${addr}
        Should Be Equal As Integers    ${got}    ${exp}    NavState word ${i} did not cross byte-exact
    END
