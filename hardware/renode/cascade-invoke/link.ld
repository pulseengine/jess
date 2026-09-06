MEMORY {
  ITCM (rwx) : ORIGIN = 0x00000000, LENGTH = 512K
  DTCM (rwx) : ORIGIN = 0x20000000, LENGTH = 256K
}
ENTRY(_reset)
_stack_top = ORIGIN(DTCM) + LENGTH(DTCM);
SECTIONS {
  .vectors 0x00000000 : { KEEP(*(.vectors)) } > ITCM
  .text : { *(.text*) } > ITCM
  /* rodata gets its OWN output section, NOT folded into .text.
     Merged, the output section inherited AX (executable) and 43,005 bytes of wasm data blob
     were mapped executable — `nm` reported jess_wasm_data_blob as `T`, not `R`. synth 0.62.0's
     `verify-embedder` refused the image over it: it must disassemble an executable region,
     hit data, and fail closed (8 refusals in jess_wasm_data_blob / _data_segs).
     That refusal is correct, and the W^X violation was real regardless of who noticed. */
  .rodata : { *(.rodata*) } > ITCM
  /* Linear memory and the globals table are RAM the harness owns; the synth object
     addresses them through fp/r9, so they are reserved here, not linked into. */
  .bss  0x20012000 : { *(.bss*) *(COMMON) } > DTCM
}
