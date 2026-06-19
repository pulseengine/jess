#!/usr/bin/env python3
"""Extract the raw firmware image + boot params from a PX4 .px4 file.

PX4 ships fmu-v6xrt firmware as a JSON wrapper (magic "PX4FWv1") whose "image"
field is base64(zlib(binary)). Renode boots the binary at the flash origin; the
i.MX RT IVT (at +0x1000) carries the ARM vector-table entry. Usage:
  extract-px4-image.py px4_fmu-v6xrt_default.px4 px4_fmu-v6xrt_default.bin
"""
import json, base64, zlib, struct, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
img = zlib.decompress(base64.b64decode(d["image"]))
open(dst, "wb").write(img)
FLASH = 0x30020000
hdr, entry, _r1, dcd, bootdata, selfp, csf, _r2 = struct.unpack_from("<8I", img, 0x1000)
sp, reset = struct.unpack_from("<2I", img, entry - FLASH)
print(f"board_id={d.get('board_id')} bytes={len(img)}")
print(f"IVT entry(vtable)=0x{entry:08x}  SP=0x{sp:08x}  Reset=0x{reset:08x}")
print(f"-> renode: sysbus LoadBinary @{dst} 0x{FLASH:08x}; cpu VectorTableOffset 0x{entry:08x}; cpu PC 0x{reset:08x}; cpu SP 0x{sp:08x}")
