(module
  (type $t2 (func (param i32 i32) (result i32)))        ;; expected type
  (type $t4 (func (param i32 i32 i32 i32) (result i32))) ;; a DIFFERENT type also in the table
  (table $tab 2 2 funcref)
  (func $add2 (type $t2) (i32.add (local.get 0) (local.get 1)))
  (func $sum4 (type $t4) (i32.const 4))
  (elem (table $tab) (i32.const 0) func $add2 $sum4)      ;; heterogeneous: slot0=t2, slot1=t4
  (func (export "dispatch") (param $sel i32) (result i32)
    (call_indirect $tab (type $t2) (i32.const 7) (i32.const 8) (local.get $sel))))
