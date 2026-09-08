;; synth#1189 / RQ-64-JOINALIAS control module.
;;
;; The defect class: on the ARM DIRECT SELECTOR (every --relocatable compile), `local.get`
;; of a register-homed local pushes the HOME REGISTER uncopied. When that is the then-arm
;; result of a value-carrying if/else, the join `mov R_then, R_else` on the else path WRITES
;; THE LOCAL — so a later `local.get` of it reads the join's value instead. Exit 0, no
;; decline, wrong answer.
;;
;; This module is the minimal shape that exhibits it: param 0 is homed in a register, it is
;; the then-arm result, and it is RE-READ after the join.
;;   f(a=7, b=0) -> else taken -> if-result = 5, so the correct answer is 5 + 7 = 12.
;;   Under synth 0.60.0 the join clobbers r0 and the code computes r0 + r0 = 14.
(module
  (func (export "joinalias") (param $a i32) (param $b i32) (result i32)
    (i32.add
      (if (result i32) (local.get $b)
        (then (local.get $a))
        (else (i32.const 5)))
      (local.get $a)))
)
