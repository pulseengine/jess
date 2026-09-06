/* .rodata is its OWN output section, never folded into .text (AFD-105: folding
   mapped 43,005 B of wasm data EXECUTABLE and synth's verify-embedder caught it). */
MEMORY {
  FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 128K
  RAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 8K
}
SECTIONS {
  .vectors : { KEEP(*(.vectors)) } > FLASH
  .text    : { *(.text*) }         > FLASH
  .rodata  : { *(.rodata*) }       > FLASH
  /DISCARD/ : { *(.ARM.exidx*) *(.comment) }
}
