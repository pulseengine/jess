(module
  (func (export "addf") (param f32 f32) (result i32)
    local.get 0 local.get 1 f32.add i32.reinterpret_f32)
  (func (export "mulf") (param f32 f32) (result i32)
    local.get 0 local.get 1 f32.mul i32.reinterpret_f32)
  (func (export "run") (result i32)
    f32.const 1.5 f32.const 2.25 f32.add i32.reinterpret_f32))
