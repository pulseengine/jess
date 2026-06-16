MEMORY {
  ITCM (rwx) : ORIGIN = 0x00000000, LENGTH = 256K
  DTCM (rwx) : ORIGIN = 0x20000000, LENGTH = 256K
}
ENTRY(reset)
_stack_top = ORIGIN(DTCM) + LENGTH(DTCM);
SECTIONS {
  .vectors 0x00000000 : { KEEP(*(.vectors)) } > ITCM
  .text : { *(.text*) *(.rodata*) } > ITCM
}
