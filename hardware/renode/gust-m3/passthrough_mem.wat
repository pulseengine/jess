(module
  (memory (export "memory") 1)
  ;; F100 gust failsafe pass-through (REQ-PIX-004 PART-P02 (a)), on-target form.
  ;; Copies the 4 input per-motor commands (mem[0..12], f32 bit patterns) to the output
  ;; block (mem[16..28]) BYTE-EXACT — pure i32 load/store, NO float op, no re-mix, no floors.
  ;; The robot writes the 4 inputs, RunFor, then reads the 4 outputs and asserts == inputs.
  (func (export "entry")
    (i32.store (i32.const 16) (i32.load (i32.const 0)))
    (i32.store (i32.const 20) (i32.load (i32.const 4)))
    (i32.store (i32.const 24) (i32.load (i32.const 8)))
    (i32.store (i32.const 28) (i32.load (i32.const 12)))))
