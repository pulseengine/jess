# jess simulation — two parallel tracks for the combined M7 + F100 vehicle

The Pixhawk 6X-RT flight system is **two nodes** cooperating. We simulate the whole
thing on **two tracks in parallel**: **wasmtime** (hardware-free, fast, the SIL of the
*portable* logic) and **Renode** (the real-hardware model, exercising the actual
synth→ARM binaries). Both run the same system; the physical board is the third rung.

```
            SENSORS                 NODES                      ACTUATORS
  IMU/baro/mag/GNSS ─SPI/I2C/UART─▶ ┌───────────────┐ ──DShot──▶ ESCs (primary)
  (relay-hal transports)           │  M7  falcon    │
  battery ──────────AdcIn────────▶ │  + relay-hal   │ ──MAVLink─▶ GCS
                                   │  (RT1176 HAL)  │ ──CAN─────▶ peripherals
                                   └──────┬────────┘
                                          │ inter-node IPC  (relay-bus carrier, relay#177 / DD-009)
                                   ┌──────┴────────┐
  RC / SBUS ──────sbus-poll──────▶│  F100  gust    │ ──pwm-write─▶ ESCs (FAILSAFE)
                                   │  (gale-nano)   │
                                   └───────────────┘
   M7 = primary sensing + control + GCS/CAN.   F100 = always-alive failsafe (RC in, failsafe PWM, fatal).
```

## Track A — wasmtime (hardware-free SIL)   [STARTED]
The portable wasm components run in wasmtime — no board, no Renode wall-clock.
- **gust failsafe:** `sim/gust-wasmtime.sh` — runs gale's `gust_kernel.wasm`, asserts
  `gust_mix(1024)==1500` (REFLASH.md's silicon kill-criterion, checked in software
  first). **PASSING.**
- **falcon control:** already covered by the SIL gate in `scripts/jess-build.sh`
  (`run-stabilization < 0.1 rad`, `run-position-hold < 0.6 m`, kiln==wasmtime).
- **Next:** a *combined* harness — falcon (M7) + gust (F100) in one wasmtime run over
  a shared simulated plant + an IPC channel, exercising the handoff (M7 healthy → gust
  passive; M7 fault → gust drives failsafe PWM).

## Track B — Renode (real-hardware model)   [node rungs done; multi-node next]
The actual synth→ARM binaries on modeled silicon.
- **M7 (RT1176):** `hardware/renode/pixhawk6xrt.repl` — boots, LPUART, bulk-mem trap
  (REQ-PIX-005/TEST-PIX-013), CI-gated.
- **F100 (gust):** gale's `gust_m3_8k.repl` — dissolved gust boots + runs at 8 KB
  (reproduced; TEST-PIX-016). gale owns the Renode CI for it.
- **Next (Stage 4):** a *multi-node* Renode emulation — RT1176 (M7) + the F100 machine
  in one `mach`, joined by the inter-node IPC link, with sensor (RESD) + motor (PWM
  capture) models. This is the "real-hardware simulation" of the whole vehicle.

## Track C — physical silicon   [staged / pending hardware]
- **F100:** `hardware/silicon/gust-vldiscovery-flash.sh` on the ordered STM32VLDISCOVERY.
- **M7:** the connected Pixhawk 6X-RT (READ-ONLY / greenlight-gated).

## Why two tracks in parallel
wasmtime gives *fast, hardware-free* feedback on the portable logic (every PR, seconds);
Renode gives *real-ISA / real-timing* fidelity (the silicon contract, WCET). Running both
on the same components means a divergence between them localizes the bug to the
synth→ARM lowering (Track B) vs the logic (Track A) — the SIL-differential discipline
(DD-010) applied to the whole vehicle, not one piece.
