#!/usr/bin/env bash
# H1: load the NXP flashloader into RAM over SDP and hand off to mboot/blhost.
#
# RAM ONLY. No flash write anywhere in this script. The flashloader is loaded at the address
# its own IVT declares (SELF = 0x2024FE00) — not a guess — and jumped to. Recovery is a power
# cycle or the ROM timeout, which has returned this board to normal PX4 five times today.
set -uo pipefail
cd ~/bench
V=./.venv/bin
LOAD=0x2024FE00

echo "=== ISP entry ==="
timeout 25 $V/python mavlink_shell.py /dev/ttyACM0 <<EOF >/dev/null 2>&1
reboot -i
EOF
for i in $(seq 1 40); do lsusb -d 1fc9:013d >/dev/null 2>&1 && break; sleep 0.5; done
lsusb -d 1fc9:013d || { echo "ROM never appeared"; exit 1; }
echo "  ROM up after $i polls"

echo "=== SDP write-file: flashloader -> $LOAD (RAM) ==="
sudo -n $V/sdphost -u 0x1fc9,0x013d write-file $LOAD ivt_flashloader.bin 2>&1 | tail -4

echo "=== SDP jump-address $LOAD ==="
sudo -n $V/sdphost -u 0x1fc9,0x013d jump-address $LOAD 2>&1 | tail -4

echo "=== does it re-enumerate as mboot (15A2:0073)? ==="
found=""
for i in $(seq 1 30); do
  lsusb -d 15a2:0073 >/dev/null 2>&1 && { found=mboot; break; }
  sleep 0.5
done
lsusb | grep -Ei "15a2|1fc9|3643" || true
[ -z "$found" ] && { echo "  mboot did NOT appear"; exit 2; }
echo "  mboot present after $i polls"

echo "=== blhost, read-only properties ==="
for p in 1 10 12 24; do
  printf -- "--- get-property %s ---\n" "$p"
  sudo -n $V/blhost -u 0x15a2,0x0073 get-property $p 2>&1 | tail -3
done
