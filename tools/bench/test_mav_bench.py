#!/usr/bin/env python3
"""Oracle for REQ-PIX-010 — the mav_bench decoder against a real committed sample.

The independent check is the MAVLink X.25 CRC (the board computed it; the decoder
either reproduces it with the right CRC_EXTRA or it doesn't). Runs in CI with no
board attached — deterministic over repro/pixhawk-bench/mavlink-sample.bin.
"""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
import mav_bench as mb

SAMPLE = os.path.join(os.path.dirname(__file__), "..", "..",
                      "repro", "pixhawk-bench", "mavlink-sample.bin")

def main():
    buf = mb.load(SAMPLE)
    assert len(buf) > 1000, f"sample too small: {len(buf)}"
    frames = list(mb.parse_frames(buf))

    crc_valid = [f for f in frames if f["crc_ok"] is True]
    assert crc_valid, "no CRC-valid frames decoded — framing or CRC is wrong"

    # The board is a single autopilot (sysid 1) speaking PX4 over MAVLink.
    hbs = [f for f in crc_valid if f["msgid"] == 0]
    assert hbs, "no CRC-valid HEARTBEAT (msgid 0) found"
    hb = mb.decode_heartbeat(hbs[0]["payload"])
    assert hb is not None, "HEARTBEAT payload too short"
    assert hbs[0]["sysid"] == 1, f"unexpected sysid {hbs[0]['sysid']}"
    assert hb["mavlink_version"] in (2, 3), f"unexpected mavlink_version {hb['mavlink_version']}"

    # ATTITUDE (used for the falcon-SIL differential) decodes to finite radians.
    import math
    for f in crc_valid:
        if f["msgid"] == 30:
            a = mb.decode_attitude(f["payload"])
            for k in ("roll", "pitch", "yaw"):
                assert math.isfinite(a[k]) and abs(a[k]) <= math.pi * 2, f"bad {k}={a[k]}"
            break

    print(f"OK — {len(frames)} frames, {len(crc_valid)} CRC-valid, "
          f"{len(hbs)} HEARTBEAT; autopilot={hb['autopilot']} type={hb['type']} sysid=1")

if __name__ == "__main__":
    main()
