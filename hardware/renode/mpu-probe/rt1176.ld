/* RT1176: code in ITCM @0, data in DTCM @0x20000000.
   _stack_top is INSIDE the granted data region (0x20000000 + 32K) — with the background
   region disabled, a stack outside any grant faults on exception entry and the probe
   would measure its own bookkeeping instead of the access under test. */
MEMORY { ITCM (rwx) : ORIGIN = 0x00000000, LENGTH = 512K
         DTCM (rwx) : ORIGIN = 0x20000000, LENGTH = 256K }
ENTRY(_reset)
_stack_top = 0x20008000;
SECTIONS { .vectors 0x00000000 : { KEEP(*(.vectors)) } > ITCM
           .text : { *(.text*) *(.rodata*) } > ITCM }
