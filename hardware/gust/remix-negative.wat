;; NEGATIVE CONTROL for the gust pass-through oracle (REQ-PIX-004 PART-P02 (a)).
;;
;; This is a stand-in for a WRONG gust failsafe that RE-MIXES the per-motor commands
;; instead of passing them through: each output = the f32 average of all four inputs
;; (a trivial symmetric mixer). It is byte-exact-equal to the input ONLY when all four
;; motors already carry the same value — so on the rank-3 rotor-out rows where motors 0
;; and 2 are ZEROED (0x00000000), the average is non-zero and the zeroed motors get a
;; spurious command. That divergence is precisely the parasitic-moment reintroduction the
;; PART-P02 MUST forbids. The oracle asserts this variant DIVERGES on the asymmetric-zero
;; rows — proving the pass-through check has teeth (a re-mix regression cannot pass).
(module
  (func (export "pt")
      (param $m0 i32) (param $m1 i32) (param $m2 i32) (param $m3 i32) (param $i i32) (result i32)
    (i32.reinterpret_f32
      (f32.div
        (f32.add
          (f32.add (f32.reinterpret_i32 (local.get $m0)) (f32.reinterpret_i32 (local.get $m1)))
          (f32.add (f32.reinterpret_i32 (local.get $m2)) (f32.reinterpret_i32 (local.get $m3))))
        (f32.const 4.0)))))
