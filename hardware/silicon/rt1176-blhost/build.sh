#!/bin/sh
# Assemble the RT1176 silicon bring-up payload. Outputs are gitignored — sig.S is the source.
set -eu
cd "$(dirname "$0")"
CC=${CC:-arm-none-eabi-gcc}
"$CC" -c -mcpu=cortex-m7 -mthumb sig.S -o sig.o
"${CC%gcc}ld" -Ttext=0x20240000 -e _start sig.o -o sig.elf
"${CC%gcc}objcopy" -O binary sig.elf sig.bin
echo "sig.bin: $(wc -c < sig.bin) bytes"
