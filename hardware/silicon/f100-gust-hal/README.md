# gust:hal doing REAL MMIO on real STM32F100 silicon (H3, first half)

`app/gust-hal-stub` returns `addr ^ 0x1E55_0000` for `read32` and drops `write32`. Its own
comment says: *"No silicon off-target. Real MMIO is the on-target rung, not this one."*
This is that rung.

## The seam

`probe.wat` imports `gust:hal/mmio`. synth lowers those imports to **undefined symbols**:

```
U read32
U write32
```

which is exactly the embedder seam jess owns — the wasm names the interface, the native side
is `gust_hal.c`, two volatile accesses and nothing else:

```
read32:   ldr r0, [r0, #0]   ; bx lr
write32:  str r1, [r0, #0]   ; bx lr
```

`build.sh` **asserts both symbols are undefined in the lowered object** before linking. Without
that assertion, a probe that had quietly stopped calling out to the HAL would still build, and
the whole rung would be measuring nothing.

`gust_hal.c` is compiled `-ffixed-r9 -ffixed-r10 -ffixed-r11` — it runs *between* synth-lowered
calls, which hold the linear-memory base, size and globals table in those registers. The build
gates on `verify-embedder`, which checks the emitted code rather than trusting the flags.

## Result, 2026-09-07 — STM32VLDISCOVERY (STM32F100, Cortex-M3), ST-LINK/V1, `fourpi` bench

```
LEG (only the CLOCK_EN word differs)     IDCODE      GPIOC_ODR   completion
  GPIOC clocked (baseline)               10016420    00000300    c0ffee00   OK
  clock NOT enabled (negative control)   10016420    00000000    c0ffee00   OK
```

**`IDCODE = 0x10016420`** — `DEV_ID[11:0] = 0x420`, the STM32F100 medium-density value line.
This is the load-bearing number: it appears **nowhere in the program**, and the stub would have
returned `0xE0042000 ^ 0x1E55_0000 = 0xFE512000`. A read that never reached the bus cannot
produce it.

### Why the control is not vacuous

- Both legs run the **byte-identical flashed image**; the only difference is one word the host
  writes at `0x20000480` before `resume`. Exactly one variable (AFD-048).
- The variable is a *physical* one: without `RCC_APB2ENR.IOPCEN`, GPIOC is unclocked and the bus
  **drops** the writes. The failing case is observable by construction, not by assertion.
- **`IDCODE` reads correctly in BOTH legs.** That isolates the control to the *write* path —
  `read32` against DBGMCU (always clocked) still works while the GPIOC writes vanish. A control
  that killed both paths would only have shown "something broke".
- The completion marker is present in **both** legs, so the control measured "the writes were
  dropped", not "the CPU never ran". The result words are poisoned with `0xDEADBEEF` at reset,
  so a `0` read-back is a real zero and not an unwritten word.

## H3's second half: what gale-nano still needs

Measured against the **pinned** artifact (`gale-nano 0.7.0`, sha256 `546531952a5c…`), with
synth 0.60.0:

```
cortex-m3    exit 0, 0 skips, 4775 B
cortex-m4f   exit 0, 0 skips, 4779 B
cortex-m7dp  exit 0, 0 skips, 4779 B
```

confirming "lowers 0 skips on all 3 cores" — **but only once `--embedder-data-init` /
`--embedder-global-init` are passed.** Without them synth refuses (`#1041`): gale-nano carries
11 active data segments. A first run of this measurement without those flags exited 1 on all
three cores, and reporting *that* as "gale-nano does not lower" would have been a false report
against a supplier.

The derived native residual — what jess still owes to run gale-nano on target — is exactly six
symbols:

| symbol | interface | status |
|---|---|---|
| `read32` | `gust:hal/mmio` | **supplied for real by this rung** |
| `poll-task` | `gust:os/taskdisp` | gale's lane; return-value polarity measured in AFD-067 |
| `deadline`, `set-deadline`, `slept-status`, `state` | timer / task state | gated on DD-025 and gale#224 |

Four of those names contain hyphens (WIT kebab-case, emitted verbatim), so a C embedder cannot
declare them: GCC's `__asm__("poll-task")` alias emits an unquoted `.type poll-task, %function`
and the assembler rejects it. Two mechanisms do work, and both are already used elsewhere in this
repo for the export side (`cascade-invoke/build.sh`): a quoted symbol in a hand-written `.S`, or
`objcopy --redefine-sym legal_name=hyphen-name`. Recorded so the next rung does not rediscover it.

## Scope

- **Executed on silicon:** `read32` and `write32` against real peripherals, Cortex-M3.
- **Not executed:** gale-nano itself — it lowers and its residual is derived, but nothing has run
  it. Nothing on the RT1176; the debug adapter is in transit.

Recovery: `run-on-silicon.sh` verifies `~/bench/f100-backup/original-flash.bin` against its
recorded sha256 and **refuses to flash** on mismatch, and self-claims the ST-Link through
`with-device` (gale drives the same probe).
