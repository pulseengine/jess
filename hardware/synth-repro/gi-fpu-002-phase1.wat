;; Minimal reproducer for GI-FPU-002 phase 1 — VFP S-register-file exhaustion.
;;
;; MECHANISM: it is not expression DEPTH, it is SIMULTANEOUS LIVENESS. A deep but
;; sequential f32 chain evaluates in 2 registers and compiles fine (which is likely
;; why a naive deep-expression attempt did not reproduce). What exhausts S0..S15 is
;; N values that must all be live AT THE SAME TIME: each is computed from the
;; parameter (so none is constant-folded away), and only then are they all consumed
;; in a single expression tree.
;;
;; BOUNDARY on synth 0.55.0, -t cortex-m7dp:  13 live -> compiles.  14 live -> fails.
;; (14 rather than 16 implies two of S0..S15 are otherwise committed.)
;;
;; Error text is character-identical to the real falcon cascade failure on
;; attitude@0.7.0#tick and ekf@0.7.0#estimate:
;;   GI-FPU-002: VFP register file exhausted (S0..S15 all live) — f32 expression too deep for phase 1
(module
  (func (export "live14") (param f32) (result f32)
    (local f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32)
    ;; 14 distinct values, each derived from the param so none folds
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
    (local.set 14 (f32.mul (local.get 0) (f32.const 14.5)))
    ;; consume all 14 in ONE tree -> all must be live simultaneously
    (f32.mul (f32.mul (f32.mul (f32.mul (f32.mul (f32.mul (f32.mul
    (f32.mul (f32.mul (f32.mul (f32.mul (f32.mul (f32.mul
      (local.get 1) (local.get 2)) (local.get 3)) (local.get 4)) (local.get 5))
      (local.get 6)) (local.get 7)) (local.get 8)) (local.get 9)) (local.get 10))
      (local.get 11)) (local.get 12)) (local.get 13)) (local.get 14))))
