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

## Status (iter#39, 2026-06-19)

✅ Local Renode validated against jess's RT1176 smoke (== CI).
✅ Real PX4 `fmu-v6xrt_default` boots and executes on the platform (IVT-derived
   entry @0x30022000). Reaches relocated ITCM code.
✅ **Clock bring-up cleared**: the 154×/324×/113× lock-poll spins on ANADIG
   (0x40C8_4000), 0x40CA_8000, and the CCM/LPCG block (0x40CC_0000) are stubbed.
🔜 Current frontier: peripheral init — GPT timers (0x4013_4000/8000), the
   always-on domain (0x40C0_xxxx: SNVS/RTWDOG), config blocks (0x400E_8000).
   Next: stub those → reach LPUART1 console → the NuttX/`nsh` banner.

## Map (where this is going)

- **Stage 2** (here): boot to `nsh` — stub/model clock+timer+console peripherals.
- **Stage 3**: ICM-42688-P over LPSPI+eDMA (RESD), baro/mag over LPI2C → live sensors.
- **Stage 4**: M4 core + MU, STM32F100 IO-MCU as a 2nd machine (the DD-012 3 targets).
- **Stage 5**: bridge sensor-in / PWM-out to **Gazebo** in lockstep (custom C# proxy
  or the SystemC `renode_bridge`) — HITL with the real firmware on Renode.
