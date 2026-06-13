(module
  (func (export "f") (param i32) (result i32)
    (block (result i32 i32) i32.const 10 i32.const 20)
    local.get 0
    select))
