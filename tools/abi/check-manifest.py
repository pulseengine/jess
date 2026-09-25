#!/usr/bin/env python3
"""Cross-check the ABI jess's harness ASSUMES against the ABI meld says it EMITTED.

WHY THIS EXISTS. jess derives the Canonical ABI shape by counting WIT record fields, and the
harness hardcodes the result: `ARGV_WORDS[18]` is rate#tick's flattened param count, and the
torque read back from rate's return area is passed FLATTENED to mixer#mix. Those are three
assumptions, and the Canonical ABI **passes garbage rather than erroring** when one is wrong —
jess has already paid for that once, assuming pointer-in for both rate and mixer.

meld 0.57.0+ emits `meld.signature-manifest` (meld#400, the shape jess argued for on that
thread: it carries `flat_param_count` AND the `return_area` layout, so a consumer can
cross-check its lowering instead of trusting it). This reads BOTH sides — the manifest and
harness.c itself — and compares. There is deliberately no third copy of the numbers here to
drift out of step.

This matters most for the falcon 0.7.0 -> 0.10.0 migration: five stage interfaces collapse to a
single `controller.step` whose sensor-frame flattens to ~26 scalars. Every number below changes,
and this gate is what turns that from a silent garbage-pass into a red build.
"""
import json, re, sys, pathlib

def manifest_from(path):
    d = pathlib.Path(path).read_bytes()
    i = d.find(b'meld.signature-manifest')
    if i < 0:
        sys.exit(f"FAIL: no meld.signature-manifest in {path}\n"
                 "   fuse with --emit-manifest (meld >= 0.57.0). Refusing to report a pass on a\n"
                 "   module that carries no manifest — that would be a verdict about nothing.")
    j = d.find(b'{', i)
    depth, k = 0, j
    while k < len(d):
        c = d[k:k+1]
        if c == b'{': depth += 1
        elif c == b'}':
            depth -= 1
            if depth == 0: break
        k += 1
    return json.loads(d[j:k+1].decode('utf-8', errors='replace'))

def argv_words_len(harness):
    src = pathlib.Path(harness).read_text()
    m = re.search(r'ARGV_WORDS\s*\[\s*(\d+)\s*\]', src)
    if not m:
        sys.exit(f"FAIL: could not find ARGV_WORDS[N] in {harness} — the gate cannot read the\n"
                 "   assumption it is supposed to check, so it must not report a pass.")
    return int(m.group(1))

def main():
    fused   = sys.argv[1] if len(sys.argv) > 1 else '.scratch/invoke/c.wasm'
    harness = sys.argv[2] if len(sys.argv) > 2 else 'hardware/renode/cascade-invoke/harness.c'
    man = manifest_from(fused)
    exports = {e['export']: e for e in man.get('exports', [])}
    if not exports:
        sys.exit("FAIL: manifest carries zero exports — nothing to check (vacuous).")
    print(f"  manifest version {man.get('version')}, {len(exports)} export(s)")

    def find(suffix):
        for k, v in exports.items():
            if k.endswith(suffix): return k, v
        sys.exit(f"FAIL: no export ending '{suffix}' in the manifest. Exports present:\n" +
                 "\n".join("     " + k for k in exports))

    ok = True
    # 1. rate#tick's flattened param count must equal the harness's ARGV_WORDS length.
    rk, rate = find('/rate@0.7.0#tick')
    want = argv_words_len(harness)
    got  = rate['flat_param_count']
    tag  = "ok " if want == got else "FAIL"
    ok  &= want == got
    print(f"  [{tag}] rate#tick flat_param_count: harness ARGV_WORDS[{want}] vs manifest {got}")

    # 2. rate#tick must be INDIRECT (>16 flat params) — the harness calls it with a pointer.
    tag = "ok " if got > 16 else "FAIL"; ok &= got > 16
    print(f"  [{tag}] rate#tick is indirect: {got} > 16 (harness passes `int arg`, a pointer)")

    # 3. rate's return area must hold the 4 torque words the harness reads back as q[0..3].
    ra = rate.get('return_area') or {}
    n  = len(ra.get('layout', []))
    tag = "ok " if n == 4 and ra.get('size') == 16 else "FAIL"; ok &= (n == 4 and ra.get('size') == 16)
    print(f"  [{tag}] rate#tick return area: {ra.get('size')} B / {n} field(s); harness reads q[0..3]")

    # 4. mixer#mix must be FLATTENED to exactly 4 — the harness calls it with 4 floats.
    mk, mix = find('/mixer@0.7.0#mix')
    mf = mix['flat_param_count']
    tag = "ok " if mf == 4 and mf <= 16 else "FAIL"; ok &= (mf == 4 and mf <= 16)
    print(f"  [{tag}] mixer#mix flattened to {mf} (harness passes 4 floats, not a pointer)")

    print("ABI-MANIFEST:", "PASS" if ok else "FAIL")
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main())
