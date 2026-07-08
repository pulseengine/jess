(module
  (type $t (func (result i32)))
  (table $t0 1 1 funcref)          ;; table 0 — what synth links at R11
  (table $t1 2 2 funcref)          ;; table 1 — the secondary table falcon uses
  (func $a (type $t) (i32.const 100))
  (func $b (type $t) (i32.const 200))
  (elem (table $t1) (i32.const 0) func $a $b)
  ;; dispatch through TABLE 1 (the failing case)
  (func (export "via_t1") (param $sel i32) (result i32)
    (call_indirect $t1 (type $t) (local.get $sel)))
  ;; control: dispatch through TABLE 0 (should compile)
  (elem (table $t0) (i32.const 0) func $a)
  (func (export "via_t0") (result i32)
    (call_indirect $t0 (type $t) (i32.const 0))))
