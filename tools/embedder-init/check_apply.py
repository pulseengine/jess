#!/usr/bin/env python3
"""Compare what the APPLY LOOP actually produced against wasmtime's instantiated memory.

tools/embedder-init/verify_init.py checks the extracted TABLES. Nothing checked the
LOOP that consumes them: a clean-room audit showed the link-clean CI step still passes
with jess_wasm_apply_init gutted to `return;`. This closes that.

Three assertions, the third of which is what makes the first two non-vacuous:
  1. every segment range in the applied image equals wasmtime's own memory
  2. every applied global equals the raw-parsed initialiser
  3. a byte OUTSIDE every segment is still POISON  -- so a loop that simply splatted
     the whole blob, or memcpy'd everything, is caught too
"""
import json, sys
from wasmtime import Store, Module, Instance, Engine

POISON = 0xEF

def main():
    mod_path, manifest, mem_path, glob_path = sys.argv[1:5]
    man = json.load(open(manifest))
    applied = open(mem_path, "rb").read()
    gbytes = open(glob_path, "rb").read()

    store = Store(Engine())
    inst = Instance(store, Module.from_file(store.engine, mod_path), [])
    mem = None
    for name, ext in inst.exports(store)._extern_map.items() if hasattr(inst.exports(store), "_extern_map") else []:
        pass
    exports = inst.exports(store)
    for cand in ("mem", "memory"):
        try:
            mem = exports[cand]; break
        except Exception:
            continue
    if mem is None:
        print("cannot-verify: module exports no memory to compare against", file=sys.stderr)
        return 3
    ref = bytearray(mem.read(store, 0, mem.data_len(store)))

    ok = True
    covered = set()
    for s in man["segments"]:
        d, n = s["offset"], s["len"]
        covered.update(range(d, d + n))
        got, want = applied[d:d+n], bytes(ref[d:d+n])
        if got != want:
            ok = False
            print(f"  MISMATCH segment {s['index']} @{d} len {n}")
            print(f"    applied: {got[:16].hex()}...")
            print(f"    wasmtime: {want[:16].hex()}...")
    if ok:
        print(f"  {len(man['segments'])} segment(s) match wasmtime's instantiated memory byte for byte")

    gvals = [int.from_bytes(gbytes[i*4:(i+1)*4], "little") for i in range(len(man["globals"]))]
    for g, got in zip(man["globals"], gvals):
        if got != g["value"] & 0xFFFFFFFF:
            ok = False
            print(f"  MISMATCH global {g['index']}: applied 0x{got:08x} want 0x{g['value']:08x}")
    if ok:
        print(f"  {len(man['globals'])} global(s) match the extracted initialisers")

    # (3) THE ANTI-SPLAT CHECK. Without it, a loop that filled everything with the blob
    # would satisfy (1) and (2) on every covered byte and still be wrong.
    outside = [i for i in range(len(applied)) if i not in covered]
    dirty = [i for i in outside if applied[i] != POISON]
    if dirty:
        ok = False
        print(f"  WROTE OUTSIDE the declared segments: {len(dirty)} byte(s), first at {dirty[0]}")
    else:
        print(f"  {len(outside)} byte(s) outside the segments are untouched (still poison)")

    print("APPLY-LOOP CHECK:", "PASS" if ok else "FAIL")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
