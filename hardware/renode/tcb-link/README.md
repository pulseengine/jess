# DD-018 TCB-link model — minimal demonstration + link oracle

Proves the **gale-maximal-wasm on-target linking model** (DD-018) on a minimal
example, **independent of the falcon #369/#275 poles**: the falcon on-target path
is `--relocatable + TCB-link` (native trusted base + fused wasm), NOT the
self-contained `--cortex-m` ELF. This shows that mechanism works end-to-end at
the link level.

## The pieces
- **`seam.wat`** — a minimal wasm: `compute() = tcb_seed() + 1`, importing the
  native primitive `env::tcb_seed` (stands in for a gale/WASI TCB primitive).
- **`tcb.S`** — a thin native TCB shim: provides `tcb_seed` (returns 0xCAFE) +
  a reset that calls `compute` and stores the result to DTCM.
- **`build.sh`** — the recipe + **link oracle**.

## The recipe (the ABI gust uses, DD-018)
```
synth compile seam.wasm -t cortex-m7dp --relocatable --native-pointer-abi --shadow-stack-size 1024
```
`--native-pointer-abi` makes the module **base-independent** (a host-pointer
drop-in, linmem base = 0), so no runtime R11/linear-memory setup is needed — the
image links against a thin native shim, not a full wasm runtime.

## Oracle (`build.sh`, exits non-zero on failure)
synth emits `compute` (defined) + **`tcb_seed` (undefined = the TCB seam)**; the
shim provides `tcb_seed`; they link into a complete ARM ELF with **0 undefined
symbols**. Negative-controlled: linking without the shim errors on the undefined
`tcb_seed` (the seam is real — synth genuinely emits it as a relocation the native
trusted base must satisfy).

```
SYNTH=/path/to/synth ./build.sh
→ LINK OK — DD-018 TCB seam fully resolved: wasm(compute) + native(tcb_seed) -> complete ARM image, 0 undefined.
```

## Next rung (not yet green)
Booting the linked image in Renode to assert `compute()` runs on real ARM (result
0xCAFF at 0x20010000). The link is proven; the on-target **execution** of the
minimal image under Renode is the next step (a boot hang under investigation —
likely a startup/vector or native-pointer-abi runtime-init detail). Not shipped
red; the link-model viability (above) is the green result. This is the minimal
analogue of `tools/bench/falcon-reloc-spike.sh` point 1 ("falcon dissolves
--relocatable to a valid ELF relocatable object; TCB-link viable").
