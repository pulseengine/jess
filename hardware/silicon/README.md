# On-silicon confirmation — dissolved gust on STM32F100 (STM32VLDISCOVERY)

The literal-silicon rung for **REQ-PIX-009 / TEST-PIX-016** — closing the
"physical F100 reflash pending hardware" caveat on the synth#383 8 KB shrink.
qemu (lm3s) gave the functional result; Renode (Cortex-M3 + 8 KB) gives the real
M3-ISA model; **this is the actual chip.** Grounded in gale `benches/gust/REFLASH.md`.

## Board (ordered — standalone eval, NOT the Pixhawk)
**STM32VLDISCOVERY** — STM32F100RBT6B: Cortex-M3, 128 KB flash @ `0x08000000`,
**8 KB SRAM** @ `0x20000000`, **onboard ST-LINK** (single USB cable, no separate
probe). ~€15. The exact part `gust` targets and Renode's `stm32vldiscovery.repl`
models. This is a standalone board — flashing it is unrestricted (the Pixhawk's
F100 stays READ-ONLY / greenlight-gated).

## Interface (what jess has)
- **openocd 0.12.0** (installed) — ST-LINK + `target/stm32f1x.cfg` (covers F100). The path this script uses.
- Alternatives (REFLASH.md): probe-rs (`--chip STM32F100RBTx`) or st-flash — both absent locally; openocd suffices.
- Heartbeat: **semihosting** (`hprintln`) forwarded by openocd (`arm semihosting enable`), not a physical UART.
- `arm-none-eabi-gdb` (px4 toolchain) available for the gdb+semihosting variant.

## Renode rung — already done by gale; jess reproduced it
gale `benches/gust/renode-test/` ships `gust_m3_8k.repl` (Cortex-M3 + 8 KB SRAM,
SemihostingUart) + `gust_renode.robot` + a committed `gust_wasm.elf`
(text 5016 / data 532 / **bss 4256** = ~4.8 KB). It runs in **gale's** CI
(`renode-tests.yml`), so jess does **not** duplicate it as a jess CI gate.

**jess local reproduction (2026-06-22, Renode v1.16.1):** loaded `gust_wasm.elf`
on `gust_m3_8k.repl` — SP initialized to `0x20002000` (top of the 8 KB SRAM),
`.bss` 4256 B loaded at `0x20000214` (inside the 8 KB window), **5,000,000
instructions executed in 0.05 s sim with no early fault**. Confirms the dissolved
gust boots + runs on the real M3 ISA model with 8 KB RAM. (`gust_f100.robot` uses
the built-in `platforms/boards/stm32vldiscovery.repl` for the semihosting-heartbeat
variant; not shipped in Renode 1.16.1 here, so the M3/8K repl was used.)

## Physical rung (run when the board arrives)
`./gust-vldiscovery-flash.sh` — fetches gale's `gust_wasm.elf`, flashes via openocd,
runs with semihosting, asserts the REFLASH.md kill-criterion (`gust_mix(1024)=1500`
+ `poll rounds, scheduler stable`). A HardFault / `mix != 1500` / no heartbeat = the
shrink mis-addressed on real silicon — exactly what synth#383 wanted surfaced before
tagging. On a clean boot: post the on-silicon line on **synth#383** + **gale#65**.
