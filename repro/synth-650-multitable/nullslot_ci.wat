(module
  (type $t (func (result i32)))
  ;; table with 3 slots but only slot 0 initialized — slots 1,2 are null funcref
  ;; (exactly falcon's fused table-1 shape: 41 declared, sparsely populated)
  (table $t1 3 3 funcref)
  (func $a (type $t) (i32.const 100))
  (elem (table $t1) (i32.const 0) func $a)
  (func (export "via_t1_sparse") (param $sel i32) (result i32)
    (call_indirect $t1 (type $t) (local.get $sel))))
