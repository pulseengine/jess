# Track B — Renode multi-node vehicle (the real-hardware mirror of the wasmtime sim)

The Renode (real ISA, modeled silicon) counterpart of `sim/vehicle-wasmtime.sh`. Same
two-node scenario (DD-019 / REQ-PIX-017), now the **full three-core topology** of the
Pixhawk 6X-RT (Stage 4): M7 + M4 on the RT1176 die + the F100 IO-MCU.

```
  mach "rt1176"  (rt1176-dualcore.repl — two cores on one shared sysbus):
      cpu_m7 : hardware/renode/smoke/rt1176-smoke.elf — bring-up, LPUART1 banner
               (real falcon pending the synth poles #369/#275)
      cpu_m4 : m4/m4-heartbeat.elf — the on-die SENSOR-OFFLOAD core (DD-018 T2),
               publishes a heartbeat to the M7<->M4 shared-memory ring
      └── SHMEM @ 0x20400000 (relay-bus carrier region, DD-009) + MU mailbox stub
  mach "f100-io" : gale gust_m3_8k.repl + gust_wasm.elf — the real dissolved failsafe
      └── FMU<->F100 link = relay-bus carrier (relay#177)
```

Run: `RENODE=~/renode-…/renode hardware/renode/vehicle/run-vehicle-multinode.sh`

## What this rung CONFIRMS
All **three cores co-execute** in one Renode emulation, and the **M7<->M4 shared-memory
link is live**:
- `cpu_m7` boots the smoke firmware → LPUART1 banner `JESS-RT1176 boot OK`.
- `cpu_m4` (Cortex-M4, FPv4-SP) runs on the shared RT1176 sysbus and **writes an
  advancing heartbeat to the SHMEM ring @ 0x20400000** (read back ~0xA2C29 after a
  short run) — proving the on-die M7<->M4 shared-memory carrier works, not just that
  the core instantiates.
- `f100-io` (gust) co-executes as the failsafe node.
Per-core NVIC via `BusPointRegistration` (Renode dual-core pattern). `rt1176-dualcore.repl`
is separate from the CI-gated `pixhawk6xrt.repl` (M7-only smoke gate), left untouched.

## What is DEFERRED (honest scope) and why
- **Reactive failsafe handoff** (gust *consuming* the M7/M4 heartbeat over `ipc-rx` and
  tripping on loss) needs a **gust build whose `ipc-rx` is wired to a connectable
  transport** — gale's `gust_m3_8k.repl` exposes only a `SemihostingUart`. Asked gale for
  the driver + access (gale#65). Until then the handoff is orchestration-modeled, exactly
  as the wasmtime track host-models it; the handoff LOGIC is proven on Track A
  (TEST-PIX-018).
- **Real falcon on the M7**, and **real sensor drivers on the M4**, are bring-up stubs
  until the synth poles (#369 hard-float / AFD-024, #275 dispatch / AFD-008) clear; the
  M4 heartbeat stands in for the sensor-offload workload.
- **The MU mailbox** is a plain-memory stub (the doorbell-IRQ semantics are a later
  increment); the shared-mem ring itself is live.

So Track B is now the three-core co-execution + a live on-die M7<->M4 shared-mem link;
full reactive behavior is gated on gale's gust-ipc + the synth poles.
