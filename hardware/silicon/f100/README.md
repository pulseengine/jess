# The gust pass-through on REAL STM32F100 silicon (H2 / TEST-PIX-028 / AFD-088 step 3)

`TEST-PIX-028` asserts the synth-compiled gust pass-through is byte-exact on a Cortex-M3.
Until 2026-09-05 the only witness was Renode — and AFD-088 recorded that the emulated platform
had been sized to fit the artifact (256 KB of SRAM against the part's 8 KB), so the emulator
could not have reproduced the failure the hardware would have.

These scripts run the **same image** against the **same relay fixture rows** on an actual
STM32F100 (STM32VLDISCOVERY, ST-LINK/V1, on the `fourpi` bench), over SWD.

## Result, 2026-09-05

```
rotor-out, motors 0+2 ZEROED   00000000 3f3ccbcb 00000000 3f3ccbcb   BYTE-EXACT
hover                          3f266666 3f266666 3f266666 3f266666   BYTE-EXACT
saturated                      3ee77cd9 3ef38916 3eeb7bad 3edf8454   BYTE-EXACT
```

3/3, including the safety-critical asymmetric rotor-out row whose zeros must survive
un-re-mixed (a re-mix reintroduces the relay v1.114 parasitic moment).

## Why the negative control exists

The outputs are **read from SRAM**. "Outputs equal inputs" is only evidence the *program* wrote
them if a non-run would look different — otherwise the check measures whatever was already in
memory. `negative-control.sh` poisons all four output words with `0xDEADBEEF`, then varies
exactly one thing: whether the CPU is resumed.

```
CPU NOT resumed : deadbeef deadbeef deadbeef deadbeef   <- the control CAN observe a non-run
CPU resumed     : 3f266666 3f266666 3f266666 3f266666   <- the program overwrote the sentinel
```

Without that row, a stale-memory reading of the same numbers would be indistinguishable from
success. This is the AFD-048 rule applied: one variable, and the failing case must be
observable.

## Recovery

The board's resident firmware is backed up **before** anything is written:

```
~/bench/f100-backup/original-flash.bin   131072 B
sha256 10969f5c35de715696c377c2ae367b9be5950698115f3f91adf479bb12a0a78b
```

Restoring it and reading the flash back yields a byte-identical image — demonstrated, not
assumed. `run-on-silicon.sh` names the backup in its own header so the recovery path travels
with the thing that needs it.

## Gotchas that cost a cycle each

- The ELF links `.text` at `0x0` (the boot alias). Real flash is at `0x08000000`; program the
  raw binary there, not the ELF.
- ST-LINK **V1J13S0 firmware is HLA-only** — `interface/stlink-hla.cfg`, not `stlink-dap.cfg`.
  openocd says so in its own error text.
- **nSRST is not wired** (`Error: SRST error` is expected and harmless here); reset over SWD.
- With HLA, a memory read on a **running** target returns nothing at all rather than erroring —
  it reads exactly like a dead probe. `halt` first.
- Everything here runs under a `with-device stlink-v1` claim; the probe is shared with gale.
