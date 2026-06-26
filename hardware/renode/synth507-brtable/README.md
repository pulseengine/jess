# synth#507 br_table runtime oracle (AFD-032 / TEST-PIX-020)

A hermetic Cortex-M3 (Renode) runtime oracle that catches synth's **optimized
(non-relocatable) path silently miscompiling `br_table`** — the selector is
elided and every arm runs. Mirrors TEST-PIX-013 (the OOB-trap oracle that became
synth#374's merge gate): it is **RED on the buggy path today** and flips **GREEN
when synth#507 lands** (the `--relocatable` path already lowers it correctly).

## The program (`brt_self.wat`)

One self-contained entry: load a selector from linear memory `mem[100]`, dispatch a
4-arm `br_table`, each arm storing a distinct constant to a distinct address:

| selector | correct result | buggy result (#507) |
|---|---|---|
| 2 | `mem[8]=30`, `mem[0]=mem[4]=mem[12]=0` | `mem[0]=10, mem[4]=20, mem[8]=30, mem[12]=40` (all arms) |

The selector is read from memory (not a constant) so synth cannot const-fold it.

## Build (synth 0.16.0, the optimized path firmware uses)

    synth compile brt_self.wat --cortex-m -t cortex-m3 -o brt_self.elf

Linear-memory base = `0x20000100` ⇒ `mem[0]=0x20000100`, `mem[8]=0x20000108`,
selector `mem[100]=0x20000164`.

## Run

    renode-test brtable-507.robot

The robot writes selector=2 to `0x20000164`, runs, and asserts `mem[8]==30` **and**
`mem[0]==0`. Today: `mem[0]==10` ⇒ **FAIL** (`10 != 0`) — the runtime proof of #507.

## Status

RED (expected) until synth#507. **Not wired into jess CI** (the 4 gates must stay
green); offered to the synth maintainer as the hermetic merge gate, as TEST-PIX-013
was for synth#374. wasmtime oracle and the `--relocatable` correct-lowering contrast:
see `repro/synth-507-brtable/`.
