# Track B — Renode multi-node vehicle (the real-hardware mirror of the wasmtime sim)

The Renode (real synth→ARM, modeled silicon) counterpart of `sim/vehicle-wasmtime.sh`.
Same two-node scenario (DD-019 / REQ-PIX-017), exercised on real ISA models instead of
in wasmtime.

```
  mach "m7-fmu"   : hardware/renode/pixhawk6xrt.repl + bring-up firmware (M7 / RT1176)
  mach "f100-io"  : gale gust_m3_8k.repl + gust_wasm.elf  (F100 / real dissolved failsafe)
       └── UARTHub "relaybus" ── the inter-node IPC link (relay-bus carrier, relay#177 / DD-009)
```

Run: `RENODE=~/renode-…/renode hardware/renode/vehicle/run-vehicle-multinode.sh`

## What this rung CONFIRMS (2026-06-22)
Both real node binaries **co-execute in one Renode emulation**: `mach` lists `m7-fmu`
(RT1176, SP 0x20040000) and `f100-io` (gust, `.bss` 4256 @ 0x20000214, SP 0x20002000 =
top of 8 KB), both `Machine started`, joined by the `relaybus` UART hub (M7 `lpuart1`
connected). This is the multi-node **topology** of the real-hardware vehicle sim — the
Track-B structural mirror of the wasmtime combined harness.

## What is DEFERRED (honest scope) and why
- **Reactive failsafe handoff** (gust *consuming* the M7 heartbeat over `ipc-rx` and
  tripping on loss) needs a **gust `ipc-rx` build with a connectable UART** — gale's
  `gust_m3_8k.repl` exposes only a `SemihostingUart`, so only the M7 side is wired to the
  hub today. Until then the handoff is **orchestration-modeled** (pausing the `m7-fmu`
  machine = M7 fault), exactly as the wasmtime track host-models the arbitration.
- **Real falcon on the M7** is a bring-up stub here because falcon's synth→ARM image is
  still blocked by the on-target punch-list (**#369 hard-float / AFD-024**, **#275
  dispatch / AFD-008**). When those land, the M7 node runs real falcon and the Renode
  rung becomes a full real-binary vehicle sim.

So Track B = multi-node co-execution + IPC scaffold **now**; full reactive handoff gated
on (a) gust `ipc-rx` (gale) and (b) the synth punch-list. The wasmtime track (Track A)
already demonstrates the *logic* of the handoff end-to-end (TEST-PIX-018) — the
SIL-differential pairing (DD-010 / DD-019) is what makes that division productive.
