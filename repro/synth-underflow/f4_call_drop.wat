(module
  (func $two (result i32 i32) i32.const 10 i32.const 20)
  (func (export "f") (result i32)
    call $two
    drop))
