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

def harness_array_len(harness, name):
    """The length the harness DECLARES for one of its input vectors. Read, never assumed: the
    gate exists to compare the harness's assumption against what meld says it emitted, so a
    gate that cannot read the assumption must not report a pass."""
    src = pathlib.Path(harness).read_text()
    # Match the DECLARATION, not the first `NAME[n]` anywhere in the file. The loose form
    # `NAME\s*\[(\d+)\]` read 10 out of a COMMENT ("== ARGV_WORDS[10] wx") the moment the
    # estimator rung documented which IMU word corresponds to which state word, and reported
    # ARGV_WORDS[10] vs manifest 18. It went red rather than mis-comparing, but a gate whose
    # reading of the source can be changed by a comment is not reading the source.
    decls = re.findall(r'\b' + name + r'\s*\[\s*(\d+)\s*\]\s*=', src)
    if len(decls) != 1:
        sys.exit(f"FAIL: expected exactly ONE `{name}[N] = ` declaration in {harness}, found "
                 f"{len(decls)}: {decls}\n"
                 "   the gate cannot read the assumption it is supposed to check, so it must\n"
                 "   not report a pass.")
    return int(decls[0])

def argv_words_len(harness):
    return harness_array_len(harness, 'ARGV_WORDS')

def main():
    fused   = sys.argv[1] if len(sys.argv) > 1 else '.scratch/invoke/c.wasm'
    harness = sys.argv[2] if len(sys.argv) > 2 else 'hardware/renode/cascade-invoke/harness.c'
    man = manifest_from(fused)
    exports = {e['export']: e for e in man.get('exports', [])}
    if not exports:
        sys.exit("FAIL: manifest carries zero exports — nothing to check (vacuous).")
    print(f"  manifest version {man.get('version')}, {len(exports)} export(s)")

    # Match on <stage>#<fn>, VERSION-AGNOSTIC, because the interface version moves on its own
    # schedule (0.7.0 -> 0.10.0 arrived with the falcon v1.139 controller rewrite while every
    # stage signature stayed byte-identical). Pinning the version here would have made this gate
    # a version tripwire rather than an ABI check.
    #
    # But a fusion whose exports carry DIFFERENT versions is a half-migrated input, so the
    # versions are asserted to agree and the one in use is printed. Silent is the failure mode.
    vers = sorted({m.group(1) for k in exports
                   if (m := re.search(r'@(\d+\.\d+\.\d+)#', k))})
    if len(vers) != 1:
        sys.exit(f"FAIL: exports do not share one interface version: {vers}\n"
                 "   a half-migrated fusion mixes versions; refusing to check an ABI that is\n"
                 "   not one interface.")
    print(f"  interface version {vers[0]} (all {len(exports)} exports agree)")

    def find(suffix):
        for k, v in exports.items():
            if re.sub(r'@\d+\.\d+\.\d+#', '#', k).endswith(suffix): return k, v
        sys.exit(f"FAIL: no export matching '{suffix}' in the manifest. Exports present:\n" +
                 "\n".join("     " + k for k in exports))

    ok = True
    # 1. rate#tick's flattened param count must equal the harness's ARGV_WORDS length.
    rk, rate = find('/rate#tick')
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
    mk, mix = find('/mixer#mix')
    mf = mix['flat_param_count']
    tag = "ok " if mf == 4 and mf <= 16 else "FAIL"; ok &= (mf == 4 and mf <= 16)
    print(f"  [{tag}] mixer#mix flattened to {mf} (harness passes 4 floats, not a pointer)")

    # 5-7. ekf#estimate — the THIRD calling shape, and the one the estimator rung added
    # (TEST-PIX-036). The cascade uses all three: rate is indirect (18 > 16), mixer is
    # flattened to 4, and ekf is flattened to 6. Assuming rate's pointer convention for ekf
    # passes a float where a pointer is read, and the Canonical ABI returns garbage rather
    # than erroring — which is the whole reason this gate reads both sides.
    ek, ekf = find('/ekf#estimate')
    ef = ekf['flat_param_count']
    iw = harness_array_len(harness, 'IMU_WORDS')
    tag = "ok " if ef == iw else "FAIL"; ok &= (ef == iw)
    print(f"  [{tag}] ekf#estimate flat_param_count: harness IMU_WORDS[{iw}] vs manifest {ef}")

    tag = "ok " if ef <= 16 else "FAIL"; ok &= ef <= 16
    print(f"  [{tag}] ekf#estimate is FLATTENED: {ef} <= 16 (harness passes {ef} floats, not a pointer)")

    # The estimator returns the 14-field vehicle-state through a return area. The harness folds
    # all fourteen words of every tick, so a return area of a different width would mean it is
    # folding either short or past the end of the record.
    era = ekf.get('return_area') or {}
    en  = len(era.get('layout', []))
    good = (en == 14 and era.get('size') == 56)
    tag = "ok " if good else "FAIL"; ok &= good
    print(f"  [{tag}] ekf#estimate return area: {era.get('size')} B / {en} field(s); harness folds 14 words")

    print("ABI-MANIFEST:", "PASS" if ok else "FAIL")
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main())
