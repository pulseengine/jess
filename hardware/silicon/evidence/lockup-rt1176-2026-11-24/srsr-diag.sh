#!/usr/bin/env bash
# One-off diagnostic (owner 2026-11-24: find the reset first). Per attempt: disarmed gate, halt,
# clear SRC_SRSR (W1C, 0x40C04010), load ekf.elf to RAM, resume, poll SRSR + DHCSR every 50 ms
# for 3 s with openocd's [ms] clock, then restore PX4 via nRST and read SRSR again.
# No flash writes. Must run inside a claim of both pixhawk-6xrt and mcu-link.
set -uo pipefail
B=~/jess-b2/bench; ELF=~/jess-b2/ev/images/ekf.elf
TTY=/dev/serial/by-id/usb-Dronecode_Project__Inc._PX4_FMU_v6XRT.x_0-if00
for d in pixhawk-6xrt mcu-link; do with-device --require-claim $d || { echo "no $d claim"; exit 2; }; done
timeout 30 python3 $B/preflight-disarmed.py $TTY --lib $B || { echo "GATE REFUSED"; exit 2; }
SR='[format 0x%08x [read_memory 0x40C04010 32 1]]'; DH='[format 0x%08x [read_memory 0xE000EDF0 32 1]]'
A=(-f $B/openocd/rt1176-swd.cfg -c init -c halt
   -c "echo \"before-clear srsr=$SR\""
   -c "mww 0x40C04010 0xFFFFFFFF"
   -c "echo \"after-clear srsr=$SR\""
   -c "load_image $ELF" -c "mww 0xE000ED08 0x00000000" -c "reg sp 0x20040000" -c "reg pc 0x8"
   -c "set T0 [ms]" -c "echo \"pre-resume dhcsr=$DH\"" -c resume)
for i in $(seq 1 60); do A+=(-c "sleep 50" -c "echo \"t=[expr {[ms]-\$T0}] srsr=$SR dhcsr=$DH\""); done
A+=(-c halt -c "reg pc" -c "echo \"w29-30 [read_memory 0x20011474 32 2]\"" -c shutdown)
timeout 120 openocd "${A[@]}" 2>&1 | grep -E "clear srsr|pre-resume|^t=|bytes written|external reset|^w29|^pc|Error|invalid"
timeout 45 openocd -f $B/openocd/rt1176-srst.cfg -c init -c "reset run" -c shutdown >/dev/null 2>&1
for i in $(seq 1 30); do grep -qx 'PX4 FMU v6XRT.x' /sys/bus/usb/devices/*/product 2>/dev/null && break; sleep 2; done
sleep 3; timeout 30 openocd -f $B/openocd/rt1176-swd.cfg -c init -c "echo \"after-restore srsr=$SR\"" -c shutdown 2>&1 | grep -E "after-restore|invalid|Error"
