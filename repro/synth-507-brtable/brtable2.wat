(module
  (memory (export "memory") 1)
  (func (export "dispatch") (param i32)
    (block (block (block (block
      (br_table 0 1 2 3 (local.get 0)))
      (i32.store (i32.const 0) (i32.const 10)) (return))
      (i32.store (i32.const 0) (i32.const 20)) (return))
      (i32.store (i32.const 0) (i32.const 30)) (return))
    (i32.store (i32.const 0) (i32.const 40))))
