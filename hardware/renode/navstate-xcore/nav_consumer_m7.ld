MEMORY { ITCM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x40000
         DTCM (rwx) : ORIGIN = 0x20000000, LENGTH = 0x40000 }
ENTRY(reset)
_m7_stack_top = 0x20040000;
SECTIONS { .vectors 0x00000000 : { KEEP(*(.vectors)) } > ITCM  .text : { *(.text*) *(.rodata*) } > ITCM }
