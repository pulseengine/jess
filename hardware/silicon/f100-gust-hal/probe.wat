;; H3, first half: gust:hal read32/write32 doing REAL MMIO on real silicon.
;;
;; app/gust-hal-stub returns `addr ^ 0x1E55_0000` for read32 and drops write32 —
;; its own comment says "No silicon off-target. Real MMIO is the on-target rung,
;; not this one." This is that rung.
;;
;; The imports lower to undefined symbols `read32`/`write32`, which IS the embedder
;; seam jess owns: the wasm names the interface, the native side is gust:hal.
;;
;; STM32F100 (STM32VLDISCOVERY) register map used here:
;;   0xE0042000  DBGMCU_IDCODE   DEV_ID[11:0] = 0x420 on this part
;;   0x40021018  RCC_APB2ENR     bit 4 = IOPCEN (GPIOC clock)
;;   0x40011004  GPIOC_CRH       PC8/PC9 config nibbles
;;   0x4001100C  GPIOC_ODR       PC8/PC9 = LD4/LD3 on this board
(module
  (import "gust:hal/mmio" "read32"  (func $r32 (param i32) (result i32)))
  (import "gust:hal/mmio" "write32" (func $w32 (param i32 i32)))

  ;; A value NOTHING in this program contains and no stub can fabricate: the
  ;; part's own ID. The stub would return 0xE0042000 ^ 0x1E55_0000 instead.
  (func (export "read_idcode") (result i32)
    (call $r32 (i32.const 0xE0042000)))

  ;; $do_clock is the ONE variable. With it, GPIOC is clocked and the ODR write
  ;; sticks; without it the peripheral is unclocked, the writes are DROPPED by the
  ;; bus, and the read-back is 0. The failing case is observable by construction.
  (func (export "gpio_probe") (param $do_clock i32) (result i32)
    (if (local.get $do_clock)
      (then (call $w32 (i32.const 0x40021018)
                       (i32.or (call $r32 (i32.const 0x40021018))
                               (i32.const 0x10)))))
    ;; PC8/PC9 -> 2 MHz push-pull output (nibble 0b0010 each)
    (call $w32 (i32.const 0x40011004)
               (i32.or (i32.and (call $r32 (i32.const 0x40011004))
                                (i32.const 0xFFFFFF00))
                       (i32.const 0x22)))
    (call $w32 (i32.const 0x4001100C) (i32.const 0x300))
    (call $r32 (i32.const 0x4001100C)))
)
