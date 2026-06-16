#!/usr/bin/env python3
"""mav_bench — read-only MAVLink bench for the connected Pixhawk 6X-RT (REQ-PIX-010).

Host-side Phase-2 verification tooling (rung 4 of the DD-010 ladder): decode the
real board's MAVLink stream over USB, identify the autopilot, and extract state
(attitude) for the differential against falcon's SIL output. READ-ONLY — this
tool never writes to the vehicle.

Correctness is gated on the MAVLink **X.25 CRC** (computed by the board over each
frame, with the per-message CRC_EXTRA) — an independent check of the framing, not
a restatement of the decoder. See tools/bench/test_mav_bench.py.

Usage:
  mav_bench.py summarize <file|->         # frame/msg counts, CRC-valid tally
  mav_bench.py identify  <file|->         # autopilot/type/mode from HEARTBEAT
  mav_bench.py attitude  <file|->         # roll/pitch/yaw (rad) from ATTITUDE
  (a serial source like /dev/cu.usbmodem01 may be passed as <file>)
"""
import sys, struct

# CRC_EXTRA for the message ids this bench validates (MAVLink common.xml).
CRC_EXTRA = {
    0: 50,    # HEARTBEAT
    1: 124,   # SYS_STATUS
    2: 137,   # SYSTEM_TIME
    30: 39,   # ATTITUDE
    31: 246,  # ATTITUDE_QUATERNION
    32: 185,  # LOCAL_POSITION_NED
    33: 104,  # GLOBAL_POSITION_INT
    74: 20,   # VFR_HUD
    105: 93,  # HIGHRES_IMU
    147: 154, # BATTERY_STATUS
    148: 178, # AUTOPILOT_VERSION
    230: 163, # ESTIMATOR_STATUS
    241: 90,  # VIBRATION
    245: 130, # EXTENDED_SYS_STATE
}
MAV_AUTOPILOT = {0: "GENERIC", 3: "ArduPilotMega", 12: "PX4"}
MAV_TYPE = {1: "FIXED_WING", 2: "QUADROTOR", 13: "HEXAROTOR", 14: "OCTOROTOR"}

def _crc16_x25(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        tmp = b ^ (crc & 0xFF)
        tmp = (tmp ^ (tmp << 4)) & 0xFF
        crc = ((crc >> 8) ^ (tmp << 8) ^ (tmp << 3) ^ (tmp >> 4)) & 0xFFFF
    return crc

def parse_frames(buf: bytes):
    """Yield dict frames synced on the MAVLink magic; crc_ok set when CRC_EXTRA known."""
    i, n = 0, len(buf)
    while i < n:
        m = buf[i]
        if m == 0xFE and i + 8 <= n:                       # MAVLink v1
            ln = buf[i+1]
            end = i + 6 + ln + 2
            if end <= n:
                msgid = buf[i+5]
                body = buf[i+1:i+6+ln]
                crc = buf[i+6+ln] | (buf[i+7+ln] << 8)
                ok = None
                if msgid in CRC_EXTRA:
                    ok = _crc16_x25(body + bytes([CRC_EXTRA[msgid]])) == crc
                if ok is not False:
                    yield {"ver": 1, "msgid": msgid, "sysid": buf[i+3],
                           "compid": buf[i+4], "len": ln,
                           "payload": buf[i+6:i+6+ln], "crc_ok": ok}
                    i = end; continue
        elif m == 0xFD and i + 12 <= n:                     # MAVLink v2
            ln = buf[i+1]; incompat = buf[i+2]
            sig = 13 if (incompat & 0x01) else 0
            end = i + 10 + ln + 2 + sig
            if end <= n:
                msgid = buf[i+7] | (buf[i+8] << 8) | (buf[i+9] << 16)
                body = buf[i+1:i+10+ln]
                crc = buf[i+10+ln] | (buf[i+11+ln] << 8)
                ok = None
                if msgid in CRC_EXTRA:
                    ok = _crc16_x25(body + bytes([CRC_EXTRA[msgid]])) == crc
                if ok is not False:
                    yield {"ver": 2, "msgid": msgid, "sysid": buf[i+5],
                           "compid": buf[i+6], "len": ln,
                           "payload": buf[i+10:i+10+ln], "crc_ok": ok}
                    i = end; continue
        i += 1

def load(path: str) -> bytes:
    if path == "-":
        return sys.stdin.buffer.read()
    with open(path, "rb") as f:
        return f.read()

def decode_heartbeat(p: bytes):
    # HEARTBEAT: custom_mode(u32) type(u8) autopilot(u8) base_mode(u8) system_status(u8) mavlink_version(u8)
    if len(p) < 9: return None
    custom, typ, ap, base, sysst, mv = struct.unpack_from("<IBBBBB", p, 0)
    return {"type": MAV_TYPE.get(typ, typ), "autopilot": MAV_AUTOPILOT.get(ap, ap),
            "base_mode": base, "system_status": sysst, "mavlink_version": mv}

def decode_attitude(p: bytes):
    # ATTITUDE: time_boot_ms(u32) roll pitch yaw rollspeed pitchspeed yawspeed (7x f32)
    if len(p) < 28: return None
    t, roll, pitch, yaw, *_ = struct.unpack_from("<Iffffff", p, 0)
    return {"roll": roll, "pitch": pitch, "yaw": yaw}

def main(argv):
    if len(argv) < 3:
        print(__doc__); return 2
    cmd, path = argv[1], argv[2]
    frames = list(parse_frames(load(path)))
    if cmd == "summarize":
        from collections import Counter
        ids = Counter(f["msgid"] for f in frames)
        okc = sum(1 for f in frames if f["crc_ok"] is True)
        print(f"frames: {len(frames)}  crc-valid: {okc}  distinct msgids: {len(ids)}")
        for mid, c in sorted(ids.items()):
            print(f"  msgid {mid:3}: {c}")
    elif cmd == "identify":
        for f in frames:
            if f["msgid"] == 0 and f["crc_ok"]:
                hb = decode_heartbeat(f["payload"])
                print(f"autopilot={hb['autopilot']} type={hb['type']} "
                      f"sysid={f['sysid']} mavlink_version={hb['mavlink_version']}")
                return 0
        print("no CRC-valid HEARTBEAT found"); return 1
    elif cmd == "attitude":
        for f in frames:
            if f["msgid"] == 30 and f["crc_ok"]:
                a = decode_attitude(f["payload"])
                print(f"roll={a['roll']:.4f} pitch={a['pitch']:.4f} yaw={a['yaw']:.4f} (rad)")
        return 0
    else:
        print(__doc__); return 2
    return 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
