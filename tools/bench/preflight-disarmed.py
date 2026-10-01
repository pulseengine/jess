#!/usr/bin/env python3
"""PRE-FLIGHT GATE: refuse to proceed unless the vehicle is provably DISARMED.

WHY THIS IS A TOOL AND NOT A FEW INLINE LINES. Anything that halts the M7, loads to RAM, or
writes flash stops the flight controller. On a quadrotor that is catastrophic if the vehicle is
armed, so the check guarding it must be (a) reusable, (b) CRC-validated, and (c) FAIL-CLOSED —
"I could not tell" must block, exactly like "it is armed".

TWO WAYS THIS WAS GOT WRONG BEFORE IT BECAME A TOOL, both worth keeping written down:

  1. A HAND-ROLLED FRAME WALKER. The first version matched 0xFE magic bytes and chained frames
     WITHOUT checking the CRC. On the real board it reported "NO HEARTBEAT" while 64,285 bytes
     streamed in 6 s — the capture was fine and the parser was not. A magic-byte walker produces
     both false negatives and false positives; `mav_bench.parse_frames` computes the MAVLink X.25
     CRC with the per-message CRC_EXTRA, so a frame it accepts is a frame the board actually sent.
     That is the AFD-128 lesson applied one layer up: do not hand-roll the decoder you already
     have a validated one for.

  2. READING THE TTY IN COOKED MODE. See AFD-128. `mav_bench.load` now routes a character device
     to a raw reader; this tool goes through it rather than opening the port itself.

THE ARMED BIT is MAV_MODE_FLAG_SAFETY_ARMED = 0x80 in HEARTBEAT's base_mode. Checked across EVERY
CRC-valid heartbeat in the window, not just the last one: a vehicle that armed mid-capture must
block, and sampling only the final heartbeat would miss it.

READ-ONLY. Opens the port O_RDONLY through mav_bench's raw reader. Nothing is written to the
vehicle and no 1200-baud touch is performed. It does NOT request AUTOPILOT_VERSION or any other
message, because requesting is a WRITE.

Exit codes, so a caller can branch:
    0  provably DISARMED      -> safe to proceed
    2  provably ARMED         -> do not proceed
    1  COULD NOT DETERMINE    -> do not proceed either ("could not run" is not "safe")

Usage:  preflight-disarmed.py [<tty>] [--seconds N] [--lib <dir holding mav_bench.py>]
"""
import sys
import os

SAFETY_ARMED = 0x80          # MAV_MODE_FLAG_SAFETY_ARMED


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    tty = args[0] if args else "/dev/ttyACM0"
    secs = 8.0
    if "--seconds" in sys.argv:
        secs = float(sys.argv[sys.argv.index("--seconds") + 1])
    if "--lib" in sys.argv:
        sys.path.insert(0, sys.argv[sys.argv.index("--lib") + 1])
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

    try:
        import mav_bench as mb
    except ImportError as e:
        print(f"  CANNOT DETERMINE: mav_bench not importable ({e}). Refusing.")
        return 1

    try:
        buf = mb.load(tty, seconds=secs)
    except Exception as e:
        # A raw-mode failure must block, not fall back to a cooked read (AFD-128).
        print(f"  CANNOT DETERMINE: reading {tty} failed ({type(e).__name__}: {e}). Refusing.")
        return 1

    frames = list(mb.parse_frames(buf))
    valid = [f for f in frames if f["crc_ok"] is True]
    hbs = [f for f in valid if f["msgid"] == 0]
    print(f"  {len(buf)} bytes in {secs:g}s, {len(frames)} frames, {len(valid)} CRC-VALID, "
          f"{len(hbs)} HEARTBEAT")

    if not hbs:
        print("  CANNOT DETERMINE: no CRC-VALID HEARTBEAT in the window. Refusing — 'I could not")
        print("  tell' blocks exactly like 'it is armed'. (Raise --seconds; HEARTBEAT is ~1 Hz.)")
        return 1

    # EVERY heartbeat, not just the last: a vehicle that armed mid-window must block.
    armed = [f for f in hbs if mb.decode_heartbeat(f["payload"])["base_mode"] & SAFETY_ARMED]
    hb = mb.decode_heartbeat(hbs[-1]["payload"])
    print(f"  autopilot={hb['autopilot']} type={hb['type']} "
          f"mavlink_version={hb['mavlink_version']}")
    print(f"  base_mode=0x{hb['base_mode']:02x} system_status={hb['system_status']}")

    if armed:
        print(f"  ARMED in {len(armed)}/{len(hbs)} heartbeats — DO NOT PROCEED.")
        return 2
    print(f"  SAFETY_ARMED clear in all {len(hbs)} heartbeats -> DISARMED, safe to proceed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
