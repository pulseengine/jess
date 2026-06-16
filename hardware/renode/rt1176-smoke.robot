*** Settings ***
Suite Setup       Setup
Suite Teardown    Teardown
Resource          ${RENODEKEYWORDS}

*** Test Cases ***
RT1176 platform boots the bring-up firmware and prints on LPUART1
    Execute Command           mach create "pixhawk6xrt"
    Execute Command           machine LoadPlatformDescription @hardware/renode/pixhawk6xrt.repl
    Execute Command           sysbus LoadELF @hardware/renode/smoke/rt1176-smoke.elf
    Create Terminal Tester    sysbus.lpuart1
    Start Emulation
    Wait For Line On Uart     JESS-RT1176 boot OK
