#!/usr/bin/env python3
"""Verify the extracted embedder-init against INDEPENDENT sources.

A verifier that re-reads the extractor's own parse would prove only that the parser
is self-consistent. Both checks here reach the same facts by a different route:

  DATA SEGMENTS — reconstruct memory from the extracted tables and compare it
    BYTE-FOR-BYTE against the memory wasmtime produces by actually instantiating the
    module. Different engine, different code path, same bytes required.

  GLOBAL INITIALISERS — re-read them from the RAW BINARY global section, not from
    `wasm-tools print` output, which is the path the extractor used.

Exit 0 only if both agree. Exit 1 on any mismatch.
"""
import json, struct, sys
from wasmtime import Store, Module, Instance, Engine


def leb128(buf, i):
    r = s = 0
    while True:
        b = buf[i]; i += 1
        r |= (b & 0x7F) << s
        if not b & 0x80: return r, i
        s += 7


def sleb128(buf, i):
    r = s = 0
    while True:
        b = buf[i]; i += 1
        r |= (b & 0x7F) << s; s += 7
        if not b & 0x80:
            if b & 0x40: r |= -(1 << s)
            return r, i


def raw_globals(path):
    """Parse the global section straight from the binary — INDEPENDENT of the WAT path."""
    buf = open(path, "rb").read()
    assert buf[:4] == b"\0asm", "not a wasm module"
    i, out = 8, []
    while i < len(buf):
        sid = buf[i]; i += 1
        size, i = leb128(buf, i)
        end = i + size
        if sid == 6:                       # global section
            n, i = leb128(buf, i)
            for _ in range(n):
                vt = buf[i]; i += 1        # valtype
                mut = buf[i]; i += 1
                op = buf[i]; i += 1
                if op == 0x41:             # i32.const
                    v, i = sleb128(buf, i)
                elif op == 0x42:           # i64.const
                    v, i = sleb128(buf, i)
                else:
                    raise SystemExit(f"non-const global init (opcode 0x{op:02x}) — cannot seed statically")
                assert buf[i] == 0x0B, "expected end opcode"; i += 1
                out.append({"type": {0x7F: "i32", 0x7E: "i64"}.get(vt, hex(vt)),
                            "mutable": bool(mut), "value": v & 0xFFFFFFFF})
            return out
        i = end
    return out


def main():
    module_path, manifest_path = sys.argv[1], sys.argv[2]
    man = json.load(open(manifest_path))
    blob_c = sys.argv[3]

    # --- rebuild the blob from the emitted C, so the C file itself is under test ---
    txt = open(blob_c).read()
    body = txt.split("jess_wasm_data_blob[] = {", 1)[1].split("};", 1)[0]
    blob = bytes(int(x, 16) for x in body.replace("\n", "").replace(" ", "").split(",") if x)

    # --- reference: what wasmtime's own instantiation puts in memory ---
    store = Store()
    inst = Instance(store, Module.from_file(store.engine, module_path), [])
    mem = inst.exports(store)["memory"]
    ref = bytes(mem.read(store, 0, mem.data_len(store)))

    # --- reconstruct from the extracted tables alone ---
    recon = bytearray(len(ref))
    off = 0
    for s in man["segments"]:
        recon[s["offset"]:s["offset"] + s["len"]] = blob[off:off + s["len"]]
        off += s["len"]

    if off != len(blob):
        print(f"FAIL: manifest covers {off} bytes but the blob holds {len(blob)}"); return 1

    if bytes(recon) != ref:
        diffs = [k for k in range(len(ref)) if recon[k] != ref[k]]
        print(f"FAIL: reconstruction differs from wasmtime's memory at {len(diffs)} byte(s); "
              f"first at 0x{diffs[0]:X} (recon 0x{recon[diffs[0]]:02X} vs wasmtime 0x{ref[diffs[0]]:02X})")
        return 1
    print(f"  data segments  OK — {len(man['segments'])} segment(s), {off} bytes, "
          f"byte-identical to wasmtime's instantiated memory ({len(ref)} B)")

    # --- globals, via the raw binary parser ---
    rg = raw_globals(module_path)
    mg = man["globals"]
    if len(rg) != len(mg):
        print(f"FAIL: {len(mg)} globals in manifest vs {len(rg)} in the binary"); return 1
    for k, (a, b) in enumerate(zip(mg, rg)):
        if a["value"] != b["value"] or a["type"] != b["type"] or a["mutable"] != b["mutable"]:
            print(f"FAIL: global {k} mismatch — manifest {a} vs binary {b}"); return 1
    print(f"  globals        OK — {len(rg)} initialiser(s) agree with the raw binary section")
    return 0


if __name__ == "__main__":
    sys.exit(main())
