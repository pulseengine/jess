#!/usr/bin/env bash
# Build the M4 producer + M7 consumer images for the NavState inter-core crossing
# oracle (TEST-PIX-030). Committed ELFs + the robot's addresses are a matched pair.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
CC="${CC:-arm-none-eabi-gcc}"; LD="${LD:-arm-none-eabi-ld}"
"$CC" -c -mcpu=cortex-m4 -mthumb "$D/nav_producer_m4.S" -o "$D/nav_producer_m4.o"
"$LD" -T "$D/nav_producer_m4.ld" "$D/nav_producer_m4.o" -o "$D/nav_producer_m4.elf"
"$CC" -c -mcpu=cortex-m7 -mthumb "$D/nav_consumer_m7.S" -o "$D/nav_consumer_m7.o"
"$LD" -T "$D/nav_consumer_m7.ld" "$D/nav_consumer_m7.o" -o "$D/nav_consumer_m7.elf"
rm -f "$D"/*.o
echo "built nav_producer_m4.elf + nav_consumer_m7.elf"
