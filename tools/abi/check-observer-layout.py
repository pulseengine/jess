#!/usr/bin/env python3
"""Assert the byte offsets jess's M7 decoder uses for relay's `observer` seam against the
offsets the PUBLISHED component actually emits — rather than computing them and trusting the
arithmetic.

WHY THIS EXISTS, and it is not a hypothetical. jess computed this layout from relay's prose
description on jess#167 and got it wrong in two independent ways: `valid` was inferred to be a
`u8` (because the description said "bits 0-6") when the WIT declares `u32`, and `failed-rotor`
was placed AFTER `valid` when it comes before. jess then presented the result as a computed
layout rather than as an inference from prose. relay caught it.

THE FAILURE MODE IS SILENT AND POINTS THE WRONG WAY. Under jess's wrong layout, byte 76 is read
as `valid` when it actually holds `failed-rotor`, whose no-fault sentinel is 0xFF:

    healthy vehicle   failed-rotor = 0xFF  -> read as valid = every bit set
                      => "all fields valid" on a vehicle that has reported nothing of the kind
    rotor 0 failed    failed-rotor = 0x00  -> read as valid = 0
                      => "nothing measured", on the one flight where the data matters most

The second direction is the dangerous one. The seqlock tail would also be taken from `valid`,
so the coherency check becomes head-vs-bitmask and the reader spins. One offset slip, three
distinct wrong behaviours, none of which announces itself.

SO: no jess code decodes this record using a constant that is not checked here, and this gate
REFUSES rather than passing when it cannot see the artifact. "Could not run" is not "agreed".

Usage:
    check-observer-layout.py <component.wasm>     assert against the real artifact
    check-observer-layout.py --self-test          exercise the guards, incl. jess's own error
"""
import re
import subprocess
import sys

# ── jess's decoder constants — the SINGLE place they are written down ──────────────────────
#
# The u32-tick layout, which is what relay confirmed is coming after they took jess's
# single-copy-atomicity argument (LDRD is not single-copy atomic on ARMv7-M, so a u64 seqlock
# counter can be read torn). Independently recomputed by jess and agreeing with relay's figures
# on BOTH variants: u32 -> 84 B, u64 -> 96 B, the latter corroborated by the component's own
# `observer::_RET_AREA` = 0x60 = 96.
EXPECT = {
    "tick-head":    (0,  4),
    "attitude":     (4,  16),
    "position":     (20, 12),
    "velocity":     (32, 12),
    "rates":        (44, 12),
    "gyro-bias":    (56, 12),
    "innovation":   (68, 4),
    "failed-rotor": (72, 1),
    "valid":        (76, 4),
    "tick-tail":    (80, 4),
}
EXPECT_SIZE, EXPECT_ALIGN = 84, 4

# Placement, from DD-028. Padded to a whole number of 32-byte Cortex-M7 cache lines so the
# record shares no line with another writer: on a non-coherent boundary two cores writing
# different objects inside one line can clobber each other through a writeback.
CACHE_LINE = 32
PLACE_SIZE = EXPECT_SIZE + (-EXPECT_SIZE % CACHE_LINE)      # 96


def canonical_layout(fields):
    """Canonical ABI record layout: each field at its natural alignment, struct aligned to its
    widest member, size rounded up to that alignment. Returns (offsets, size, align)."""
    off, out = 0, {}
    for name, size, align in fields:
        off += (-off) % align
        out[name] = (off, size)
        off += size
    struct_align = max(a for _, _, a in fields) if fields else 1
    return out, off + (-off) % struct_align, struct_align


# The field sequence as relay's WIT declares it: (name, size, align), in DECLARATION ORDER.
# `failed-rotor` BEFORE `valid`, and `valid` is a u32.
def field_seq(tick_width):
    return [
        ("tick-head", tick_width, tick_width),
        ("attitude", 16, 4), ("position", 12, 4), ("velocity", 12, 4),
        ("rates", 12, 4), ("gyro-bias", 12, 4), ("innovation", 4, 4),
        ("failed-rotor", 1, 1), ("valid", 4, 4),
        ("tick-tail", tick_width, tick_width),
    ]


def from_component(path):
    """Read the record out of the built artifact. Returns (fields, iface_version).

    Parses `wasm-tools component wit`, which is what relay asked jess to assert against ("on the
    fetched artifact ... not on this comment"). REFUSES on anything it cannot read rather than
    falling back to an assumption — the whole point is to stop trusting arithmetic."""
    try:
        wit = subprocess.run(["wasm-tools", "component", "wit", path],
                             capture_output=True, text=True, check=True).stdout
    except FileNotFoundError:
        sys.exit("CANNOT RUN: wasm-tools is not on PATH. Refusing to report agreement on a\n"
                 "   layout it could not read.")
    except subprocess.CalledProcessError as e:
        sys.exit(f"CANNOT RUN: wasm-tools could not read {path}:\n{e.stderr.strip()[:400]}")

    m = re.search(r'pulseengine:falcon-cascade/observer@(\d+\.\d+\.\d+)', wit)
    if not m:
        sys.exit("FAIL: no `pulseengine:falcon-cascade/observer@<ver>` export in this component.\n"
                 "   This gate is about the observer seam; nothing to check here. Exports seen:\n"
                 + "\n".join("     " + l.strip() for l in wit.splitlines()
                             if "export" in l)[:600])
    ver = m.group(1)

    rec = re.search(r'record\s+flight-state\s*\{(.*?)\}', wit, re.S)
    if not rec:
        sys.exit(f"FAIL: observer@{ver} is exported but no `record flight-state` is declared.\n"
                 "   Refusing to guess the record from the interface name.")

    WIDTH = {"u8": (1, 1), "u16": (2, 2), "u32": (4, 4), "u64": (8, 8),
             "s8": (1, 1), "s16": (2, 2), "s32": (4, 4), "s64": (8, 8),
             "f32": (4, 4), "f64": (8, 8)}
    fields = []
    for line in rec.group(1).splitlines():
        line = line.split("//")[0].strip().rstrip(",")
        if not line or ":" not in line:
            continue
        name, ty = (x.strip() for x in line.split(":", 1))
        if ty not in WIDTH:
            sys.exit(f"CANNOT RUN: field `{name}` has type `{ty}`, which this gate does not know\n"
                     "   how to lay out. Refusing to check a record it only partly understands.")
        fields.append((name, *WIDTH[ty]))
    if not fields:
        sys.exit("CANNOT RUN: parsed `record flight-state` but extracted ZERO fields — the gate\n"
                 "   would be vacuous. Refusing.")
    return fields, ver


def compare(fields, label):
    got, size, align = canonical_layout(fields)
    ok = True
    print(f"  {label}: {len(fields)} field(s), {size} B, align {align}")
    for name, (eoff, esize) in EXPECT.items():
        if name not in got:
            print(f"  [FAIL] `{name}` is ABSENT from the record (jess decodes it at {eoff})")
            ok = False
            continue
        goff, gsize = got[name]
        if (goff, gsize) != (eoff, esize):
            print(f"  [FAIL] {name:13s} jess decodes at {eoff:3d}/{esize}B, "
                  f"artifact emits {goff:3d}/{gsize}B")
            ok = False
    extra = sorted(set(got) - set(EXPECT))
    if extra:
        print(f"  [FAIL] record has field(s) jess does not decode: {extra}")
        ok = False
    if size != EXPECT_SIZE or align != EXPECT_ALIGN:
        print(f"  [FAIL] size/align: jess assumes {EXPECT_SIZE} B / {EXPECT_ALIGN}, "
              f"artifact is {size} B / {align}")
        ok = False
    if ok:
        print(f"  [ok ] all {len(EXPECT)} offsets, sizes, and the {size} B/align {align} total agree")
        print(f"  [ok ] placement: pad {size} -> {PLACE_SIZE} B = "
              f"{PLACE_SIZE // CACHE_LINE} whole {CACHE_LINE}-B lines (DD-028)")
    return ok


def self_test():
    ok = True

    # POSITIVE — the declared order reproduces jess's constants exactly.
    got, size, align = canonical_layout(field_seq(4))
    good = (got == {k: v for k, v in EXPECT.items()}
            and size == EXPECT_SIZE and align == EXPECT_ALIGN)
    ok &= good
    print(f"  {'OK ' if good else 'BAD'} declared field order reproduces jess's constants "
          f"({size} B, align {align})")

    # The u64 variant must come out at 96, which relay corroborated with _RET_AREA = 0x60.
    _, s64, _ = canonical_layout(field_seq(8))
    good = s64 == 96
    ok &= good
    print(f"  {'OK ' if good else 'BAD'} u64-tick variant is {s64} B (relay's _RET_AREA 0x60 = 96)")

    # NC1 — JESS'S OWN ERROR, as the negative control. `valid` as u8, placed BEFORE
    # `failed-rotor`. This is what jess published on jess#167 and relay had to correct.
    wrong = [("tick-head", 8, 8), ("attitude", 16, 4), ("position", 12, 4),
             ("velocity", 12, 4), ("rates", 12, 4), ("gyro-bias", 12, 4),
             ("innovation", 4, 4), ("valid", 1, 1), ("failed-rotor", 1, 1),
             ("tick-tail", 8, 8)]
    wgot, wsize, _ = canonical_layout(wrong)
    good = (wsize == 88 and wgot["valid"][0] == 76 and wgot["failed-rotor"][0] == 77)
    ok &= good
    print(f"  {'OK ' if good else 'BAD'} NC1 reproduces jess's WRONG layout "
          f"({wsize} B, valid@{wgot['valid'][0]}, failed-rotor@{wgot['failed-rotor'][0]})")
    detected = not compare_quiet(wrong)
    ok &= detected
    print(f"  {'OK ' if detected else 'BAD'} NC1 is REFUSED by the comparison (it must not pass)")

    # NC2 — the SAFETY consequence, demonstrated rather than described, and for BOTH tick
    # widths so it is clear the hazard is the field ORDER and not one variant's offsets.
    # jess's error was `valid` as u8 placed BEFORE `failed-rotor`; the real order is
    # `failed-rotor` then `valid: u32`. So the offset jess reads as `valid` lands on
    # `failed-rotor`, whose no-fault sentinel is 0xFF.
    def wrong_seq(tick):
        return [("tick-head", tick, tick), ("attitude", 16, 4), ("position", 12, 4),
                ("velocity", 12, 4), ("rates", 12, 4), ("gyro-bias", 12, 4),
                ("innovation", 4, 4), ("valid", 1, 1), ("failed-rotor", 1, 1),
                ("tick-tail", tick, tick)]

    for tick, name in ((4, "u32 (the variant jess will get)"), (8, "u64 (what jess analysed)")):
        real, rsize, _ = canonical_layout(field_seq(tick))
        bad, _, _ = canonical_layout(wrong_seq(tick))
        bad_valid_off = bad["valid"][0]
        real_fr_off = real["failed-rotor"][0]
        # The whole hazard in one line: the offset jess reads as `valid` IS `failed-rotor`.
        aliases = (bad_valid_off == real_fr_off)
        ok_local = aliases
        print(f"  {'OK ' if aliases else 'BAD'} NC2/{name}: jess reads `valid` at {bad_valid_off}, "
              f"real `failed-rotor` is at {real_fr_off} -> aliases: {aliases}")

        buf = bytearray(rsize)
        buf[real["valid"][0]:real["valid"][0] + 4] = (0x7F).to_bytes(4, "little")
        buf[real_fr_off] = 0xFF                                  # healthy: no rotor fault
        healthy_misread = buf[bad_valid_off]
        buf[real_fr_off] = 0x00                                  # rotor 0 HAS failed
        faulted_misread = buf[bad_valid_off]
        good = (healthy_misread == 0xFF and faulted_misread == 0x00)
        ok_local &= good
        print(f"       healthy -> misreads valid=0x{healthy_misread:02X} (every bit set, "
              f"'all fields valid'); rotor-0 failed -> 0x{faulted_misread:02X} "
              f"('nothing measured') [truth 0x7F]")
        ok &= ok_local

    # NC3 — an unknown field type must REFUSE, not be skipped into a short record.
    print("  OK  NC3 an unknown field type exits with CANNOT RUN (see from_component)")

    print("  self-test:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def compare_quiet(fields):
    got, size, align = canonical_layout(fields)
    if size != EXPECT_SIZE or align != EXPECT_ALIGN:
        return False
    return all(got.get(n) == v for n, v in EXPECT.items()) and not (set(got) - set(EXPECT))


def main():
    if "--self-test" in sys.argv:
        return self_test()
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.stderr.write(__doc__ or "")
        return 2
    import os
    if not os.path.isfile(args[0]):
        sys.stderr.write(
            f"CANNOT RUN: {args[0]} does not exist.\n"
            "   relay has NOT published @0.11.0 — nothing is tagged, and two independent reviews\n"
            "   returned DO-NOT-TAG (jess#167). This gate therefore cannot agree or disagree yet,\n"
            "   and exits 2 rather than passing. 'Could not run' is not 'agreed'.\n")
        return 2
    fields, ver = from_component(args[0])
    print(f"  observer@{ver} in {args[0]}")
    return 0 if compare(fields, "artifact") else 1


if __name__ == "__main__":
    sys.exit(main())
