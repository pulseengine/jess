(module
  (func $two (result i32 i32) i32.const 10 i32.const 20)
  (func (export "f") (param i32) (result i32)
    call $two
    local.get 0
    select))
