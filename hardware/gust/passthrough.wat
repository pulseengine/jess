;; F100 gust failsafe — per-motor command PASS-THROUGH (REQ-PIX-004 PART-P02 (a)).
;;
;; The gust failsafe on the F100 forwards the M7's per-motor commands BYTE-EXACT:
;; no re-mixing, no per-motor floors. This is the load-bearing safety property —
;; a rank-3 rotor-out set with motors asymmetrically ZEROED must survive un-re-mixed,
;; else the re-mix reintroduces the parasitic moment that caused the relay v1.114 failure.
;;
;; Implementation: the motor command is an f32 bit pattern; pass-through copies the
;; i32 BITS unchanged (NO float op → no FPU, no rounding, no re-mix). This is exactly
;; what makes it byte-exact AND F100-friendly (STM32F100 = Cortex-M3, soft-float / no FPU).
(module
  ;; pt(m0,m1,m2,m3, i) -> the i-th motor command, unchanged (identity on the i32 bit pattern).
  (func (export "pt")
      (param $m0 i32) (param $m1 i32) (param $m2 i32) (param $m3 i32) (param $i i32) (result i32)
    (block $d (block $c (block $b (block $a
      (br_table $a $b $c $d (local.get $i)))
      (return (local.get $m0)))
      (return (local.get $m1)))
      (return (local.get $m2)))
    (local.get $m3)))
