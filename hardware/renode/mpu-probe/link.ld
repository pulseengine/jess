MEMORY {
  ITCM (rwx) : ORIGIN = 0x00000000, LENGTH = 512K
  DTCM (rwx) : ORIGIN = 0x20000000, LENGTH = 256K
}
ENTRY(_reset)
_stack_top = ORIGIN(DTCM) + LENGTH(DTCM);
SECTIONS {
  .vectors 0x00000000 : { KEEP(*(.vectors)) } > ITCM
  .text : { *(.text*) *(.rodata*) } > ITCM
  /* Linear memory and the globals table are RAM the harness owns; the synth object
     addresses them through fp/r9, so they are reserved here, not linked into. */
  .bss  0x20012000 : { *(.bss*) *(COMMON) } > DTCM
}
