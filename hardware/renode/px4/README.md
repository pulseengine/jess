# PX4-on-Renode bring-up (i.MX RT1176 / Pixhawk 6X-RT) — DD-008 stage 2→5

Booting the **real PX4 `fmu-v6xrt` firmware** on jess's hand-authored RT1176 Renode
platform, via the DD-008 **boot → unhandled-access → stub/model** loop, toward an
`nsh` console — then sensor-in-the-loop (stage 3), multi-core (stage 4), and a
**Gazebo HITL bridge** (stage 5). This is original work (no PX4-in-Renode existed).

## Toolchain (not committed — fetch locally)

```sh
# 1. Renode (pinned v1.16.1, matches CI). macOS arm64 self-contained build:
curl -fsSLO https://github.com/renode/renode/releases/download/v1.16.1/renode-1.16.1-dotnet.osx-arm64-portable.dmg
hdiutil attach renode-1.16.1-dotnet.osx-arm64-portable.dmg -nobrowse
cp -R /Volumes/Renode_1.16.1/Renode.app ~/renode-1.16.1 && hdiutil detach /Volumes/Renode_1.16.1
RENODE=~/renode-1.16.1/Contents/MacOS/renode   # (Linux CI uses the linux-portable tarball)

# 2. PX4 reference firmware (prebuilt — no PX4 build needed):
curl -fsSLO https://github.com/PX4/PX4-Autopilot/releases/latest/download/px4_fmu-v6xrt_default.px4
python3 hardware/renode/px4/extract-px4-image.py px4_fmu-v6xrt_default.px4 /tmp/px4-v6xrt.bin
```

## Run the boot loop

```sh
$RENODE --console --disable-xwt \
  -e 'set PX4BIN @/tmp/px4-v6xrt.bin' \
  -e 'include @hardware/renode/px4/px4-boot.resc' \
  -e 'logLevel 1; emulation RunFor "0.1"; cpu PC; quit' 2>&1 \
  | grep -oE 'non existing peripheral at 0x[0-9A-Fa-f]+' | sort | uniq -c | sort -rn
```

Each high-count address is a **spin-wait on a peripheral** the model is missing.
Add a stub for it in `pixhawk6xrt-px4-extras.repl` (broad regions use the bundled
`scripts/pydev/flipflop.py`, which flip-flops reads 0/0xFFFFFFFF so lock/ready/busy
polls pass either polarity), re-run, advance to the next frontier. Replace stubs
with real C# peripheral models (or re-based imxrt1064 models) as semantics matter.

## Status (iter#40, 2026-06-19)

✅ Local Renode validated against jess's RT1176 smoke (== CI).
✅ Real PX4 `fmu-v6xrt_default` boots and executes on the platform (IVT-derived
   entry @0x30022000). Reaches relocated ITCM/OCRAM code.
✅ **Clock bring-up cleared**: the 154×/324×/113× lock-poll spins on ANADIG
   (0x40C8_4000), 0x40CA_8000, and the CCM/LPCG block (0x40CC_0000) are stubbed
   (flip-flop). AON/GPT/config blocks are plain memory (return-0/stored) — broad
   flip-flop there corrupts *data* reads (all-ones used as a pointer → branch to
   0xFFFFFFFE), so only genuine lock-bit polls get flip-flop.
✅ **CONSOLE REACHED** — PX4 drives LPUART1: emits its first byte (`B`),
   deterministically across runs. The low-level putc path (clocks up, peripheral
   clocked) works. Oracle: `run-px4-boot.sh` (asserts ≥1 console byte).
🔎 **Next frontier ROOT-CAUSED (iter#42):** after `B`, at PC `0x20242E72` the
   firmware reads **`0x0021_001C`** then branches to `0xFFFFFFFE` → CPU abort.
   `0x0021_001C` is the **i.MX RT1170/1176 ROM-API tree pointer** (the boot-ROM
   bootloader API root, per the RT1170 RM) — NuttX/PX4 reads it to get the
   FlexSPI-NOR ROM driver. jess's `.repl` doesn't model the boot ROM, so the read
   returns 0, NuttX dereferences a null tree (offset lands in ITCM @0x0), gets
   garbage, and branches to `0xFFFFFFFE`. So the blocker is the **boot ROM / ROM
   API**, not a missing MMIO poll.
   **Fix path:** model the boot ROM region (`0x0020_0000`) with a minimal ROM-API
   tree at `0x0021_001C` → a stub `flexspi_nor_driver_interface_t` whose ops return
   success (FlexSPI is already plain memory in the model, so the ops are no-ops).
   To stub only the functions NuttX actually calls (and get the struct offsets
   right), this needs **PX4 symbols** — building PX4 fmu-v6xrt from source for the
   symbol'd ELF (the raw `.px4` has none).

## PX4 built from source — boot path fully DECODED (iter#43)

Built PX4 fmu-v6xrt from source (pinned Arm GNU 12.3.Rel1 toolchain + full python
deps, under /Volumes/Home) → a symbol'd `.elf` (20,314 symbols). With symbols the
fault resolves exactly: PC `0x20242E72` = **`imxrt_octl_flash_initialize`**, which:
```
memcpy(cfg, 0x30256aa8, 512); *cfg = 'FCFB';
ROM_API_Init();                       // [chipver 0x40C84800]==const ? base 0x200000 : 0x210000
                                      //   tree = *(base + 0x1C); g_bootloaderTree = tree
ROM_FLEXSPI_NorFlash_Init(1, cfg);    // ( *(tree+12) )->( +4 )()   = flexSpiNorDriver->init
ROM_FLEXSPI_NorFlash_ClearCache(1);   // no-op when chipver == 0x001170A0
```
**Exact ROM-API ABI (decoded from the wrappers):**
- chip-version reg **`0x40C84800`** (ANADIG+0x800, DIGPROG) must read **`0x001170A0`**
  (RT1176) — else base-select + ClearCache go wrong.
- ROM-API tree pointer at **`base+0x1C`** (`0x0020001C` *and* `0x0021001C` — write both).
- tree (`bootloader_api_entry_t`): **`flexSpiNorDriver` at +12**.
- driver (`flexspi_nor_driver_interface_t`): **`version` at +0, `init` at +4**, then
  page_program/erase_all/erase/read/get_config/erase_sector/erase_block.

A stub built to this ABI (anadig_stub.py = DIGPROG 0x001170A0 + flip-flop; bootrom
@0x00200000; tree→driver→success stubs) moved the abort from `0xFFFFFFFE` (null tree)
to **`0x00220000`** — i.e. the firmware now reaches *past* Init and calls a **real
boot-ROM function** beyond the 128 KB stub. That's the crux: the i.MX RT boot ROM
does real work; returns-0 stubs only go so far.

### Two clean paths to nsh (next iteration)
1. **Rebuild PX4 with flash-init skipped for emulation** (preferred — source+toolchain
   are now set up): no-op `imxrt_octl_flash_initialize` for a Renode board variant.
   FlexSPI is already plain memory in the model, so real flash init is unneeded →
   the whole romapi dependency disappears → straight to nsh.
2. **Full romapi stub**: map the real ROM address space + stub every function the
   firmware calls (deeper, brittle).
Then: symbol'd-ELF boot (VTOR 0x30022000, SP 0x20259994, PC 0x300223a9) for exact
backtraces → nsh banner → line-based robot oracle into CI.

## Path 1 EXECUTED (iter#44) — romapi wall REMOVED; new frontier = Renode throughput

Took path 1: rebuilt PX4 fmu-v6xrt with **`CONFIG_BOARD_BOOTLOADER_FIXUP=n`** (a
Renode board variant — the Kconfig default is `n`, so the line is just removed from
`boards/px4/fmu-v6xrt/nuttx-config/nsh/defconfig`). Result confirmed:
- **`imxrt_octl_flash_initialize` is ABSENT** from the rebuilt ELF (`nm` shows it
  gone) → `imxrt_boardinitialize` now calls `imxrt_flash_setup_prefetch_partition`
  directly (the direct-register path, no ROM) and continues NuttX init.
- **The romapi abort is GONE** — the firmware no longer branches to `0xFFFFFFFE` /
  reaches the real boot-ROM at `0x00220000`. The documented hard wall is eliminated.
  New boot vectors for this variant: VTOR `0x30022000`, SP `0x20258f94`, PC `0x300223a9`.
- New frontier diagnosed: after the first console byte `B` the firmware runs real
  NuttX init and sits in **`up_mdelay`** (PC `0x3005c4e2`) — a *software busy-delay*
  loop (`CONFIG_BOARD_LOOPSPERMSEC=104926`), **not** a missing peripheral and **not**
  a fault. It is wall-clock-pathological in Renode: 0.3 s of simulated time costs
  >180 s wall on this model (the M7 burns many cycles through init/delays).
- Mitigation tried: a variant with **`CONFIG_BOARD_LOOPSPERMSEC=100`** (≈1000× cheaper
  delays) — still does not reach the nsh banner within a feasible short sim, so the
  bottleneck is **Renode interpretation throughput on the model's CPU clock**, not the
  delay calibration alone.

**So path 1 achieved its objective** (remove the boot-ROM/romapi dependency — the thing
that actually blocked progress) and advanced the boot from "aborts at romapi" to "runs
NuttX init." Reaching the full nsh banner is now a **Renode performance-tuning** task,
not a firmware-logic wall — next levers: lower the modeled CPU frequency in
`pixhawk6xrt.repl`, tune `cpu PerformanceInMips` / the sync quantum, or fast-skip the
init delays; then line-based robot oracle into CI.

> **Strategic scope (DD-016/DD-017):** PX4→nsh is a **reference / model-fidelity**
> exercise — jess's *flight* image is the all-wasm synth build (no NuttX, no romapi,
> load-to-RAM in TCM), so the boot ROM is off the flight path *by design*. Path 1's
> romapi-removal is the load-bearing validation; brute-forcing PX4 all the way to nsh
> is bounded-value polish on a reference target, gated on Renode throughput tuning.

> Honest scope: still the **console-reached** sub-milestone (one byte `B`), NOT a full
> `nsh` boot — but the romapi wall (the prior blocker) is now removed. Stage 2 stays in
> progress, re-pointed at Renode throughput.

## Map (where this is going)

- **Stage 2** (here): boot to `nsh` — stub/model clock+timer+console peripherals.
- **Stage 3**: ICM-42688-P over LPSPI+eDMA (RESD), baro/mag over LPI2C → live sensors.
- **Stage 4**: M4 core + MU, STM32F100 IO-MCU as a 2nd machine (the DD-012 3 targets).
- **Stage 5**: bridge sensor-in / PWM-out to **Gazebo** in lockstep (custom C# proxy
  or the SystemC `renode_bridge`) — HITL with the real firmware on Renode.
