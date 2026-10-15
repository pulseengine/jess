# The three gravity blocks, measured at their own load PCs

synth#1487 (v0.82.0) named six PCs — three blocks, each an addend and a multiplicand load — and
said the runtime values were NOT obtained: no qemu on the release machine, jess's repo not cloned
there, and a request naming the six PCs "drafted and not sent". These are those values.

Mapping: synth's PCs are object-relative (`cascade.o` `.text` at VMA 0). Delta to jess's linked
image is **0x2e4**, identical across all 25 shared `func_*` symbols, and verified by disassembling
at the mapped addresses and matching all six `[sp,#N]` offsets (200, 152, 216, 232, 192, 208).
Each block materialises `0x411CF5C3` = 9.81f inline via MOVW/MOVT.

Captured with `hardware/qemu/memtrace` windowed to `pclo=2770 pchi=2810`, so each word is sampled
AT ITS OWN LOAD PC — necessary because `[sp,#152]` is a reused spill home referenced 130 times in
this object, so a slot name identifies no single value.

IMU `(0, 0, -9.81, 0.30, -0.15, 0.07)`, the module's own dt = 1 ms.

**Every block computes `addend + multiplicand * 9.81` — 48 of 48 exact over 16 ticks x 3 blocks.**
The down axis takes `az = -9.81` and stores ~1e-6. The three results
(`0x20001358`/`0x2000135c`/`0x20001360`) are read 240 times each, all from one consumer at ELF pc
`0x33c0`. So the compensation is PRESENT, exact, and consumed — which REFUTES AFD-134's
"missing or zero-valued addend" mechanism while leaving its measurements intact.

| tick | block | addend (hex / f32) | multiplicand | stored result |
|---|---|---|---|---|
| 1 | blk1 (N) | `00000000` +0.000000e+00 | `399d489e` +2.999948e-04 | `3b40de7d` +2.942949e-03 |
| 1 | blk2 (E) | `00000000` +0.000000e+00 | `391d4c24` +1.500105e-04 | `3ac0e2cf` +1.471603e-03 |
| 1 | blk3 (D) | `c11cf5c3` -9.810000e+00 | `3f7fffff` +9.999999e-01 | `b5800000` -9.536743e-07 |
| 2 | blk1 (N) | `00000000` +0.000000e+00 | `39d30f06` +4.025625e-04 | `3b8167c6` +3.949138e-03 |
| 2 | blk2 (E) | `00000000` +0.000000e+00 | `39531629` +2.013078e-04 | `3b016c26` +1.974830e-03 |
| 2 | blk3 (D) | `c11cf5c3` -9.810000e+00 | `3f7ffffe` +9.999999e-01 | `b5800000` -9.536743e-07 |
| 8 | blk1 (N) | `00000000` +0.000000e+00 | `3aa81fb4` +1.282683e-03 | `3c4e2970` +1.258312e-02 |
| 8 | blk2 (E) | `00000000` +0.000000e+00 | `3a2833fe` +6.416439e-04 | `3bce4251` +6.294527e-03 |
| 8 | blk3 (D) | `c11cf5c3` -9.810000e+00 | `3f7fffef` +9.999990e-01 | `b7200000` -9.536743e-06 |
| 16 | blk1 (N) | `00000000` +0.000000e+00 | `3b22754a` +2.478915e-03 | `3cc736de` +2.431815e-02 |
| 16 | blk2 (E) | `00000000` +0.000000e+00 | `3aa29c3b` +1.240618e-03 | `3c47669f` +1.217046e-02 |
| 16 | blk3 (D) | `c11cf5c3` -9.810000e+00 | `3f7fffc0` +9.999962e-01 | `b81c0000` -3.719330e-05 |
