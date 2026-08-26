;; NEGATIVE CONTROL for gi-fpu-002-phase1.wat — identical shape, 13 live instead of 14.
;; MUST COMPILE. If this one also fails, the fixture is not isolating liveness.
(module
  (func (export "live13") (param f32) (result f32)
    (local f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32)
    (local.set 1  (f32.mul (local.get 0) (f32.const 1.5)))
    (local.set 2  (f32.mul (local.get 0) (f32.const 2.5)))
    (local.set 3  (f32.mul (local.get 0) (f32.const 3.5)))
    (local.set 4  (f32.mul (local.get 0) (f32.const 4.5)))
    (local.set 5  (f32.mul (local.get 0) (f32.const 5.5)))
    (local.set 6  (f32.mul (local.get 0) (f32.const 6.5)))
    (local.set 7  (f32.mul (local.get 0) (f32.const 7.5)))
    (local.set 8  (f32.mul (local.get 0) (f32.const 8.5)))
    (local.set 9  (f32.mul (local.get 0) (f32.const 9.5)))
    (local.set 10 (f32.mul (local.get 0) (f32.const 10.5)))
    (local.set 11 (f32.mul (local.get 0) (f32.const 11.5)))
    (local.set 12 (f32.mul (local.get 0) (f32.const 12.5)))
    (local.set 13 (f32.mul (local.get 0) (f32.const 13.5)))
    (f32.mul (f32.mul (f32.mul (f32.mul (f32.mul (f32.mul
    (f32.mul (f32.mul (f32.mul (f32.mul (f32.mul (f32.mul
      (local.get 1) (local.get 2)) (local.get 3)) (local.get 4)) (local.get 5))
      (local.get 6)) (local.get 7)) (local.get 8)) (local.get 9)) (local.get 10))
      (local.get 11)) (local.get 12)) (local.get 13))))
