(module
  (import "env" "tcb_seed" (func $seed (result i32)))
  (func (export "compute") (result i32)
    (i32.add (call $seed) (i32.const 1))))
