/* stm32f4_discovery-kit: code in flash @0x08000000, SRAM @0x20000000 (128K).
   Same stack rule as rt1176.ld. */
MEMORY { FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 1024K
         SRAM (rwx) : ORIGIN = 0x20000000, LENGTH = 128K }
ENTRY(_reset)
_stack_top = 0x20008000;
SECTIONS { .vectors 0x08000000 : { KEEP(*(.vectors)) } > FLASH
           .text : { *(.text*) *(.rodata*) } > FLASH }
