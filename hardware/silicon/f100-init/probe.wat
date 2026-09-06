;; The two instantiation promises AFD-046 declared to synth, made observable.
;;
;; synth --relocatable emits code that reads linear memory through R11 and globals
;; through R9 but carries NEITHER the active data segments NOR the globals' initial
;; values. --embedder-data-init / --embedder-global-init emit BYTE-IDENTICAL code:
;; they convert a refusal into an acknowledgement that the EMBEDDER owes the state.
;;
;; This module's two exports read exactly those two things and nothing else, so an
;; unkept promise is a WRONG VALUE rather than a subtle drift:
;;   read_data   -> ldr r0, [r11, #0x100]   the active data segment
;;   read_global -> ldr r0, [r9]            the globals table slot 0
;;
;; The global is NAMED on purpose: a named const global is the input that used to be
;; refused as "a non-const initialiser" by extract_init.py's parser.
(module
  (memory (export "mem") 1)
  (global $g (mut i32) (i32.const 0x5A5A0000))
  (data (i32.const 0x100) "\11\22\33\44")
  (func (export "read_data")   (result i32) (i32.load (i32.const 0x100)))
  (func (export "read_global") (result i32) (global.get $g))
)
