MEMORY { OCRAM (rwx) : ORIGIN = 0x20240000, LENGTH = 0x10000 }
ENTRY(reset)
_m4_stack_top = 0x20250000;
SECTIONS { .vectors 0x20240000 : { KEEP(*(.vectors)) } > OCRAM  .text : { *(.text*) *(.rodata*) } > OCRAM }
