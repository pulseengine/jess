*** Settings ***
Resource          ${RENODEKEYWORDS}
*** Test Cases ***
Invoke rate tick on ARM
    Execute Command    mach create "inv"
    Execute Command    machine LoadPlatformDescription @/Volumes/Home/git/pulseengine/jess/hardware/renode/pixhawk6xrt.repl
    Execute Command    sysbus LoadELF @/Volumes/Home/git/pulseengine/jess/hardware/renode/cascade-m7/falcon-cascade-m7.elf
    # boot: init linmem, set r9, init globals, then spin at 0x16c
    Execute Command    emulation RunFor "0.05"
    ${pc}=   Execute Command    cpu PC
    Log To Console    BOOTED_PC=${pc}
    ${r9}=   Execute Command    cpu GetRegister 9
    Log To Console    R9=${r9}
    # write the SAME argument vector the wasmtime reference used, at linmem+0x2280
    # vehicle-state: qw..innovation (14 f32), then rate-setpoint (4 f32)
    Execute Command    sysbus WriteDoubleWord 0x20002380 0x3F800000
    Execute Command    sysbus WriteDoubleWord 0x20002384 0x00000000
    Execute Command    sysbus WriteDoubleWord 0x20002388 0x00000000
    Execute Command    sysbus WriteDoubleWord 0x2000238C 0x00000000
    Execute Command    sysbus WriteDoubleWord 0x20002390 0x00000000
    Execute Command    sysbus WriteDoubleWord 0x20002394 0x00000000
    Execute Command    sysbus WriteDoubleWord 0x20002398 0xC0200000
    Execute Command    sysbus WriteDoubleWord 0x2000239C 0x3DCCCCCD
    Execute Command    sysbus WriteDoubleWord 0x200023A0 0xBE4CCCCD
    Execute Command    sysbus WriteDoubleWord 0x200023A4 0x3D4CCCCD
    Execute Command    sysbus WriteDoubleWord 0x200023A8 0x3E99999A
    Execute Command    sysbus WriteDoubleWord 0x200023AC 0xBE19999A
    Execute Command    sysbus WriteDoubleWord 0x200023B0 0x3D8F5C29
    Execute Command    sysbus WriteDoubleWord 0x200023B4 0x00000000
    Execute Command    sysbus WriteDoubleWord 0x200023B8 0x3F800000
    Execute Command    sysbus WriteDoubleWord 0x200023BC 0x00000000
    Execute Command    sysbus WriteDoubleWord 0x200023C0 0x00000000
    Execute Command    sysbus WriteDoubleWord 0x200023C4 0x3F000000
    # call rate#tick(0x2280) — wasm-relative pointer, return to the spin
    Execute Command    cpu SetRegister 0 0x2280
    Execute Command    cpu LR 0x16D
    Execute Command    cpu PC 0x7A4
    Execute Command    cpu Step 200000
    ${pc2}=  Execute Command    cpu PC
    Log To Console    AFTER_PC=${pc2}
    ${r0}=   Execute Command    cpu GetRegister 0
    Log To Console    RET_R0=${r0}
