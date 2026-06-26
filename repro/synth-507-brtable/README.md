# synth#507 — optimized-path br_table silent miscompile (AFD-032)

`brtable2.wat`: a 4-way `br_table`, each arm stores a distinct constant then returns.

## Oracle (wasmtime)
    wasm-tools ... ; for i in 0 1 2 3: dispatch(i) -> mem[0] = 10,20,30,40   (one store, selected)

## synth 0.16.0 — optimized (non-relocatable) path: WRONG
    synth compile brtable2.wat -t cortex-m3 --cortex-m -o b.elf
    arm-none-eabi-objdump -d b.elf   # dispatch: no cmp/branch, local 0 never read,
                                     # all four stores run -> always mem[0]=40

## synth 0.16.0 — --relocatable path (gust/falcon ship here): CORRECT
    synth compile brtable2.wat -t cortex-m3 --relocatable --all-exports -o b.o
    arm-none-eabi-objdump -d b.o     # cmp r0,#0/#1/#2; beq to distinct arms

Scope: gust's only br_table (kiln_async TaskTable::transition) dissolves --relocatable
and lowers correctly — no shipped artifact is wrong today. Optimized-path latent hazard.
Same family as synth#500/#483.
