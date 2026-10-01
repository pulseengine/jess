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

    # ── NEGATIVE CONTROL: cooked-mode mangling must DESTROY framing (AFD-128) ──────────────
    #
    # This gate has only ever run against the committed sample, so the SERIAL path the module
    # documents was never exercised and `load`'s plain `open(path,"rb")` went unnoticed for
    # months. Measured on the real board, same 8 s window, raw mode the only difference:
    #     cooked   4,701 bytes,    588 B/s, longest chained frame run 3
    #     raw     89,768 bytes, 11,221 B/s, 2,119 frames, 18 msgids
    # The failure is not a byte shortfall, it is a CONFIDENT WRONG ANSWER: the cooked capture
    # decoded as "NOT MAVLink", which jess reported and had to retract.
    #
    # Hardware cannot be a prerequisite for catching that again, so the mangling is modelled as
    # a pure function and applied to the SAME sample this test already trusts. No board needed.
    mangled = mb.mangled_by_line_discipline(buf)
    assert mangled != buf, (
        "the cooked-mode model changed NOTHING on this sample, so this control proves nothing. "
        "It needs a sample containing CR bytes; pick one that does rather than deleting the check.")
    m_valid = [f for f in mb.parse_frames(mangled) if f["crc_ok"] is True]
    assert len(m_valid) < len(crc_valid), (
        f"cooked-mode mangling left {len(m_valid)} CRC-valid frames vs {len(crc_valid)} raw — "
        "it must DESTROY framing, otherwise raw mode is not load-bearing and this control is inert")
    lost = 100.0 * (len(crc_valid) - len(m_valid)) / len(crc_valid)
    print(f"NC OK — cooked-mode mangling drops CRC-valid frames {len(crc_valid)} -> "
          f"{len(m_valid)} ({lost:.1f}% lost), so raw mode is load-bearing")

    # And the reader must REFUSE a character device it cannot put in raw mode, rather than
    # silently falling back to the cooked read that caused this.
    import inspect
    src = inspect.getsource(mb.load)
    assert "S_ISCHR" in src and "read_tty_raw" in src, (
        "load() no longer routes character devices to the raw reader — the AFD-128 defect is back")
    print("NC OK — load() routes character devices to the raw reader")

if __name__ == "__main__":
    main()
