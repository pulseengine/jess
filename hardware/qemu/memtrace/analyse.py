#!/usr/bin/env python3
"""Answer synth#1436's question from a memtrace: do the rotation's quaternion loads resolve to
the addresses the attitude update stores to?

WHAT SYNTH ASKED FOR, verbatim (synth#1436, 2026-10-01):
    "the QEMU run, watching which addresses the rotation's quaternion loads actually resolve to
     against the ones the attitude update stores. That decides it without reconstructing the
     dataflow."
and why it cannot be read statically, also theirs:
    "all 236 `r11` accesses are register-offset, none constant-offset. So 'the update writes one
     field, the rotation reads another' cannot be settled by comparing offsets — the addresses
     are computed at runtime."

THE SHAPE THIS LOOKS FOR, AND WHY IT IS THE ONLY ONE WORTH LOOKING FOR. Memory is coherent: a
load that follows a store to the SAME address in the same tick cannot return the old value. So
"a stale read" cannot mean that. What it can mean — and what a lagged attitude would look like
in a trace — is TWO ADDRESSES HOLDING ONE LOGICAL FIELD: the update stores the new value to A,
and the consumer loads from B, where B still holds a value A held on an earlier tick. That is
detectable from addresses and values alone, with no model of the filter and no dataflow
reconstruction — which is exactly the property that makes it worth measuring rather than arguing.

A STALE COPY, stated as the predicate this script decides:
    there are ticks i < n and addresses A != B such that
      * A was stored value v at tick i,
      * A was stored a DIFFERENT value at tick n   (so A moved on and v is genuinely stale),
      * B was LOADED with value v at tick n        (so the consumer is still reading the old one)

WHAT THIS SCRIPT WILL NOT DO. It will not say which pc is "the rotation" or "the attitude
update". jess does not have synth's disassembly and will not guess a mapping and then present
the guess as a measurement — AFD-127 was exactly that, an inferred field layout reported as
computed. The script reports (address, load pc, store pc, tick, value); naming the function is
synth's half, and the pcs are what make it a lookup for them rather than a re-derivation.

VACUITY GUARDS, because an empty answer here is the dangerous one. "No stale copies found" and
"the tracer was not wired up" both produce no findings. So this script REFUSES to report unless
  * the trace carries memtrace's trailer and its `seen` count is nonzero,
  * a POTENCY CONTROL access is present — a store whose address and value are known in advance
    from the image (the completion sentinel). If the tracer cannot see a store we know happened,
    it cannot be trusted to have seen the ones we are asking about,
  * tick segmentation found the expected number of ticks.
Each failure exits 2 (CANNOT DETERMINE), never 0.

Usage:
  analyse.py <trace> [--elf <ekf.elf>] [--ticks 16] [--marker-pc <hex>]
             [--sentinel-addr 20011478] [--sentinel-value 1e55e4f0]
             [--max-addrs-per-value 16]
  analyse.py --self-test
Exit: 0 report produced, 1 a stale copy was found, 2 CANNOT DETERMINE.
"""
import re
import subprocess
import sys
from collections import defaultdict

CANNOT = 2


def log(*a):
    print(*a)


def parse(path):
    """-> (events, trailer) where an event is (seq, pc, addr, size, rw, value)."""
    events, trailer = [], None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#"):
                if "trailer" in line:
                    trailer = line.strip()
                continue
            f = line.split()
            if len(f) != 6:
                continue
            events.append((int(f[0]), f[1], f[2], int(f[3]), f[4], f[5]))
    return events, trailer


def symbols(elf):
    """addr -> name, from nm. Used only to LABEL pcs, never to decide anything."""
    try:
        out = subprocess.run(["nm", "--defined-only", elf], capture_output=True,
                             text=True, check=True).stdout
    except Exception as e:                                   # noqa: BLE001
        log(f"  note: no symbols ({e}); pcs will be unlabelled")
        return []
    syms = []
    for line in out.splitlines():
        m = re.match(r"^([0-9a-f]{8}) ([TtWw]) (\S+)$", line.strip())
        if m:
            syms.append((int(m.group(1), 16), m.group(3)))
    return sorted(syms)


def label(syms, pc_hex):
    if not syms:
        return pc_hex
    pc = int(pc_hex, 16)
    lo, name = None, None
    for a, n in syms:
        if a <= pc:
            lo, name = a, n
        else:
            break
    return f"{pc_hex} ({name}+0x{pc - lo:x})" if name is not None else pc_hex


def segment(events, marker_pc, nticks):
    """Split the event stream into ticks at each occurrence of marker_pc.

    The marker is a pc the HARNESS executes once per iteration, so a tick boundary is an
    observed event rather than a guess about the loop's shape. If it does not occur nticks
    times the segmentation is refused: mis-segmented ticks would make every per-tick claim
    below meaningless, in a way that still prints neatly.
    """
    hits = [i for i, e in enumerate(events) if e[1] == marker_pc]
    if len(hits) != nticks:
        return None, f"marker pc {marker_pc} occurs {len(hits)} times, expected {nticks}"
    # Segments START at the marker, so each one is ONE WHOLE INVOCATION plus the result copy
    # that follows it. Ending them at the marker instead — the obvious first try — puts the
    # tail of invocation n-1 and the head of invocation n in the same segment, which would make
    # a cross-tick value comparison compare halves of two different ticks.
    # Everything before the first marker is INITIALISATION, not a tick, and is dropped: the
    # image paints its linear memory there, so folding it into tick 0 would make every first
    # store look like a per-tick store.
    ticks = [events[hits[i]:hits[i + 1]] for i in range(len(hits) - 1)]
    ticks.append(events[hits[-1]:])
    return ticks, None


def find_marker(events, nticks, pc_max=0x2e4):
    """Pick the lowest harness-range pc that occurs exactly nticks times."""
    counts = defaultdict(int)
    for e in events:
        counts[e[1]] += 1
    cands = sorted(p for p, c in counts.items() if c == nticks and int(p, 16) < pc_max)
    return cands[0] if cands else None


def stale_copies(ticks, max_addrs=16):
    """Decide the predicate in the module docstring. -> (findings, skipped_values).

    A VALUE ONLY IDENTIFIES A FIELD IF IT IS DISTINCTIVE, and that is a limit on the method,
    not a tuning knob. The predicate traces a value from the address that stored it to the
    address that loaded it; if the same bit pattern was stored to a thousand addresses it
    identifies nothing, and every load of it would pair with every store — which is both
    meaningless and quadratic.
    Measured on the 16-tick ekf trace: 15,193 of 15,295 distinct stored values go to 8 or
    fewer addresses, then there is a gap, and the only values above 16 are `deadbeef` (1,792
    addresses — the harness's memory paint), `0` (987), `3f800000` i.e. 1.0 (62) and
    `80000000` i.e. -0.0 (56). So the cutoff separates real data from fill, and it is reported
    rather than applied silently.
    THE BLIND SPOT THIS LEAVES, stated because it bears directly on the question: at tick 1 the
    quaternion IS the identity, (1.0, 0, 0, 0) — exactly the excluded values. So this cannot see
    a stale copy of the tick-1 quaternion. It can see ticks 2..n, where the components are
    distinctive, and that is the regime synth's tick-16 evidence is in.
    """
    # stored[addr] = [(tick, value, pc), ...]   loads[addr] = [(tick, value, pc), ...]
    stored, loads = defaultdict(list), defaultdict(list)
    for t, evs in enumerate(ticks):
        for _, pc, addr, size, rw, val in evs:
            if size != 4:
                continue
            (stored if rw == "W" else loads)[addr].append((t, val, pc))

    # value -> {(addr, tick)} for stores, so a load's value can be traced to where it came from.
    by_value = defaultdict(set)
    addrs_per_value = defaultdict(set)
    for addr, lst in stored.items():
        for t, val, _pc in lst:
            by_value[val].add((addr, t))
            addrs_per_value[val].add(addr)
    skipped = {v: len(a) for v, a in addrs_per_value.items() if len(a) > max_addrs}
    for v in skipped:
        by_value.pop(v, None)

    findings = []
    for baddr, lst in loads.items():
        for t, val, lpc in lst:
            for aaddr, at in by_value.get(val, ()):
                if aaddr == baddr or at >= t:
                    continue
                # A must have MOVED ON by tick t, else v is still current and not stale.
                later = [(tt, vv) for tt, vv, _ in stored[aaddr] if at < tt <= t]
                if not later or all(vv == val for _tt, vv in later):
                    continue
                spc = next(pc for tt, vv, pc in stored[aaddr] if (tt, vv) == (at, val))
                findings.append({
                    "value": val, "store_addr": aaddr, "store_tick": at, "store_pc": spc,
                    "load_addr": baddr, "load_tick": t, "load_pc": lpc,
                })
    return findings, skipped


# ── self-test: both directions, on synthetic traces ──────────────────────────────────────────
def self_test():
    """The detector must FIND an injected stale copy and must find NOTHING without one.

    One direction alone is worthless: a detector that reports every pair would pass the positive
    case, and one that reports nothing would pass the negative. Both, on inputs differing in
    exactly one event, is what pins it.
    """
    ok = True

    def mk(rows):
        # rows: (pc, addr, rw, val) per tick-group, marker closes each tick
        evs, seq = [], 0
        for group in rows:
            evs.append((seq, "00000240", "20011400", 4, "R", "0"))   # the tick marker, FIRST
            seq += 1
            for pc, addr, rw, val in group:
                evs.append((seq, pc, addr, 4, rw, val))
                seq += 1
        return evs

    # tick0: A<-aaa, B<-aaa   tick1: A<-bbb, and B is READ as aaa  => stale copy
    pos = mk([
        [("1000", "2000a000", "W", "aaa"), ("1004", "2000b000", "W", "aaa")],
        [("1000", "2000a000", "W", "bbb"), ("2000", "2000b000", "R", "aaa")],
    ])
    # NEGATIVE CONTROL: identical except B is refreshed to bbb before being read, so the read
    # is current. ONE variable: the value B holds at the read.
    neg = mk([
        [("1000", "2000a000", "W", "aaa"), ("1004", "2000b000", "W", "aaa")],
        [("1000", "2000a000", "W", "bbb"), ("1004", "2000b000", "W", "bbb"),
         ("2000", "2000b000", "R", "bbb")],
    ])

    for name, evs, want in (("positive", pos, True), ("negative control", neg, False)):
        ticks, err = segment(evs, "00000240", 2)
        if err:
            log(f"  {name}: SEGMENTATION FAILED — {err}")
            ok = False
            continue
        got, _skipped = stale_copies(ticks)
        hit = any(f["store_addr"] == "2000a000" and f["load_addr"] == "2000b000" for f in got)
        if hit == want:
            log(f"  {name:17} {'found' if hit else 'none'} (expect "
                f"{'found' if want else 'none'}) OK")
        else:
            log(f"  {name:17} {'found' if hit else 'none'} (expect "
                f"{'found' if want else 'none'}) FAIL")
            ok = False

    # THE THIRD CASE, which is the one that would otherwise be reported as "none found": a
    # stale copy whose VALUE is not distinctive. The detector cannot see it, and the difference
    # between "looked and found nothing" and "never looked" has to survive into the output.
    wide = mk([
        [("1000", f"2000{i:04x}", "W", "aaa") for i in range(0, 40, 4)],
        [("1000", "2000a000", "W", "bbb"), ("2000", "2000b000", "R", "aaa")],
    ])
    ticks, err = segment(wide, "00000240", 2)
    got, skipped = stale_copies(ticks, max_addrs=4)
    if "aaa" in skipped and not got:
        log("  blind-spot case     value excluded as non-distinctive, and REPORTED as skipped "
            "OK")
    else:
        log(f"  blind-spot case     skipped={list(skipped)} findings={len(got)} FAIL")
        ok = False

    # And the segmentation guard itself must refuse a wrong tick count rather than carry on.
    _, err = segment(pos, "00000240", 99)
    if err:
        log("  segmentation guard  refuses a wrong tick count OK")
    else:
        log("  segmentation guard  ACCEPTED a wrong tick count FAIL")
        ok = False

    log("  self-test: " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    pos = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not pos:
        log(__doc__)
        return CANNOT
    trace = pos[0]

    def opt(name, default):
        return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default

    elf = opt("--elf", None)
    nticks = int(opt("--ticks", "16"))
    marker = opt("--marker-pc", None)
    s_addr = opt("--sentinel-addr", "20011478")
    s_val = opt("--sentinel-value", "1e55e4f0")

    events, trailer = parse(trace)
    log(f"== {trace}: {len(events)} events ==")

    # ── guard 1: the trace must say the tracer ran ──
    if not trailer:
        log("  CANNOT DETERMINE: no memtrace trailer. An unterminated trace may be truncated,")
        log("  and a truncated trace's 'no findings' says nothing. Refusing.")
        return CANNOT
    log(f"  {trailer}")
    m = re.search(r"seen=(\d+)", trailer)
    if not m or int(m.group(1)) == 0:
        log("  CANNOT DETERMINE: the tracer saw ZERO accesses, so it was never wired up.")
        return CANNOT

    # ── guard 2: POTENCY. A store we know happened must be visible. ──
    seen_sentinel = any(a == s_addr and rw == "W" and v == s_val
                        for _, _, a, _, rw, v in events)
    if not seen_sentinel:
        log(f"  CANNOT DETERMINE: the potency control is absent — no store of {s_val} to "
            f"{s_addr}.")
        log("  That store is the image's completion sentinel and it certainly happened. A tracer")
        log("  that missed it cannot be trusted to have seen the accesses under test, so a")
        log("  'no stale copies' result here would be vacuous. Refusing.")
        return CANNOT
    log(f"  potency control: store of {s_val} to {s_addr} IS in the trace")

    # ── guard 3: segmentation ──
    if marker is None:
        marker = find_marker(events, nticks)
        if marker is None:
            log(f"  CANNOT DETERMINE: no harness-range pc occurs exactly {nticks} times, so "
                f"tick boundaries could not be established. Pass --marker-pc.")
            return CANNOT
        log(f"  tick marker (auto): pc {marker}, {nticks} occurrences")
    ticks, err = segment(events, marker, nticks)
    if err:
        log(f"  CANNOT DETERMINE: {err}")
        return CANNOT
    log(f"  segmented into {len(ticks)} ticks "
        f"({min(len(t) for t in ticks)}-{max(len(t) for t in ticks)} events each)")

    syms = symbols(elf) if elf else []

    # ── the measurement ──
    max_addrs = int(opt("--max-addrs-per-value", "16"))
    findings, skipped = stale_copies(ticks, max_addrs)
    if skipped:
        log(f"  {len(skipped)} value(s) excluded as non-distinctive (stored to more than "
            f"{max_addrs} addresses, so they identify no field):")
        for v, n in sorted(skipped.items(), key=lambda kv: -kv[1])[:6]:
            log(f"      {v} -> {n} addresses")
        log("    THE BLIND SPOT THAT LEAVES: a stale copy of one of those values is NOT visible")
        log("    here. That includes the tick-1 identity quaternion (1.0, 0, 0, 0). Ticks 2..n,")
        log("    where the components are distinctive, ARE covered.")
    log("")
    log("== STALE-COPY PREDICATE: an address loaded with a value another address has moved on "
        "from ==")
    if not findings:
        log("  NONE FOUND, and the guards above say that is an answer rather than a silence.")
        log("  So the divergence is NOT a second linear-memory location holding a stale copy of")
        log("  a field the update rewrote. It does not clear the register/arithmetic path, and")
        log("  it does not name an instruction; it removes one shape.")
        return 0

    # Group by (store_addr, load_addr) so one logical field is one row, not one row per tick.
    groups = defaultdict(list)
    for f in findings:
        groups[(f["store_addr"], f["load_addr"])].append(f)
    log(f"  {len(findings)} event(s) over {len(groups)} address pair(s):")
    for (a, b), fs in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        ticks_hit = sorted({f["load_tick"] for f in fs})
        lpcs = sorted({f["load_pc"] for f in fs})
        spcs = sorted({f["store_pc"] for f in fs})
        log(f"    store {a} -> load {b}   {len(fs)} event(s), ticks {ticks_hit[:8]}"
            f"{'...' if len(ticks_hit) > 8 else ''}")
        for p in spcs[:3]:
            log(f"      stored by pc {label(syms, p)}")
        for p in lpcs[:3]:
            log(f"      loaded by pc {label(syms, p)}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
