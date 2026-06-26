# synth#507 br_table runtime gate (AFD-032 / TEST-PIX-020)

A hermetic Cortex-M3 (Renode) runtime gate for synth's `br_table` lowering on the
optimized (non-relocatable) path. **RESOLVED**: synth **v0.17.0** (PR #508,
"optimized path declines br_table to the direct selector") fixed the miscompile;
this oracle is now **GREEN and wired into the `renode-smoke` CI job** as a permanent
regression gate. Mirrors TEST-PIX-013 (the OOB-trap oracle that gated synth#374).

## The program (`brt_self.wat`)

One self-contained entry: load a selector from linear memory `mem[100]`, dispatch a
4-arm `br_table`, each arm storing a distinct constant to a distinct address:

| selector | correct (≥ v0.17.0) | #507 bug (≤ v0.16.0) |
|---|---|---|
| 2 | `mem[8]=30`, `mem[0]=mem[4]=mem[12]=0` | `mem[0]=10, mem[4]=20, mem[8]=30, mem[12]=40` (all arms) |

The selector is read from memory (not a constant) so synth cannot const-fold it.

## Build (the committed `brt_self.elf` = synth 0.17.0)

    synth compile brt_self.wat --cortex-m -t cortex-m3 -o brt_self.elf

Linear-memory base for the committed ELF = **`0x20000000`** ⇒ `mem[0]=0x20000000`,
`mem[8]=0x20000008`, selector `mem[100]=0x20000064`. **The ELF and the robot's
address literals are a matched pair** — rebuild both together if you regenerate the
ELF on a newer synth (the base can shift between versions; it was `0x20000100` on 0.16.0).

## Run

    renode-test brtable-507.robot

Writes selector=2 to `0x20000064`, runs, asserts `mem[8]==30` **and**
`mem[0]==mem[4]==mem[12]==0`. GREEN on v0.17.0; a #507 regression sets `mem[0]=10` ⇒ FAIL.

## See also

`repro/synth-507-brtable/` — the wasmtime oracle and the `--relocatable` correct-lowering
contrast that originally characterized the bug.
