(module
  (memory (export "memory") 1)
  ;; single entry (func 0): selector loaded from mem[100] (=2) so it can't const-fold;
  ;; per-case store to a distinct address. correct -> only mem[8]=30; broken -> all set.
  (func (export "entry")
    (block
      (block
        (block
          (block
            (br_table 0 1 2 3 (i32.load (i32.const 100))))
          (i32.store (i32.const 0) (i32.const 10))
          (return))
        (i32.store (i32.const 4) (i32.const 20))
        (return))
      (i32.store (i32.const 8) (i32.const 30))
      (return))
    (i32.store (i32.const 12) (i32.const 40)))
  (data (i32.const 100) "\02\00\00\00"))
