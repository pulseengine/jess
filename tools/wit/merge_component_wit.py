#!/usr/bin/env python3
"""Union the WIT packages carried by several shipped components into one package.

WHY THIS EXISTS
---------------
`wasm-tools component wit <artifact>.wasm` recovers a component's WIT — but each
component ships a TREE-SHAKEN copy of its shared package, carrying only the type
definitions that component happens to use. For a multi-component interface family
the complete package therefore exists in NO SINGLE COMPONENT, and must be unioned.

Observed on pulseengine:falcon-cascade@0.7.0 (falcon-v1.134.1, five components):

    rate      vehicle-state, rate-setpoint, torque-setpoint
    iekf      imu-sample, vehicle-state
    position  vehicle-state, waypoint, attitude-setpoint
    attitude  vehicle-state, attitude-setpoint, rate-setpoint
    mixer     torque-setpoint, motor-pwm

Taking any one and using it fails downstream. Concatenating them fails immediately
with `error: name 'imu-sample' is not defined`, because the `ekf` interface
references a record only `iekf`'s copy defines.

MERGE SEMANTICS — and the one that matters
------------------------------------------
  * interfaces      union by name
  * type defs       union by name
  * a name defined identically in several components   -> fine, keep one
  * a name defined DIFFERENTLY in several components   -> HARD ERROR, never resolved silently

That last rule is the whole point. An earlier version of this script used
`dict.setdefault`, which keeps the FIRST definition and silently discards a
differing one — data loss with no build error. On the falcon cascade today four
records are defined in more than one component and all four are byte-identical, so
that bug produced correct output by luck. It would not have stayed lucky.

Comparison is on whitespace-normalised bodies so that cosmetic formatting
differences between extractions do not raise a false conflict.
"""
import argparse, re, subprocess, sys


def extract(artifact: str, package: str) -> str:
    """Return the body of `package` as carried by one component, or '' if absent."""
    out = subprocess.run(["wasm-tools", "component", "wit", artifact],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"error: wasm-tools failed on {artifact}: {out.stderr.strip()}")
    m = re.search(rf'^package {re.escape(package)} \{{\n(.*?)^\}}', out.stdout, re.S | re.M)
    if not m:
        return ""
    return "\n".join(l[2:] if l.startswith("  ") else l for l in m.group(1).split("\n"))


def norm(s: str) -> str:
    return re.sub(r'\s+', ' ', s).strip()


def self_test() -> int:
    """Negative control: prove the conflict path FIRES rather than resolving silently.

    This is the property rules_wasm_component#626 was worried about, so it is
    demonstrated here rather than asserted. Run: --self-test
    """
    a = "  record vehicle-state {\n    qw: f32,\n  }"
    b_same = "  record vehicle-state {\n    qw: f32,\n  }"
    b_fmt = "  record vehicle-state {\n\n    qw:   f32,\n  }"      # cosmetic only
    b_diff = "  record vehicle-state {\n    qw: f64,\n  }"          # REAL conflict

    def merge(x, y):
        store, conflicts = {}, []
        def put(name, body, src):
            if name in store:
                prev, psrc = store[name]
                if norm(prev) != norm(body):
                    conflicts.append(f"{name}: {psrc} vs {src}")
                return
            store[name] = (body, src)
        put("vehicle-state", x, "A"); put("vehicle-state", y, "B")
        return conflicts

    cases = [
        ("identical definitions",        merge(a, b_same), False),
        ("whitespace-only difference",   merge(a, b_fmt),  False),
        ("REAL conflict (f32 vs f64)",   merge(a, b_diff), True),
    ]
    ok = True
    for label, conflicts, want in cases:
        got = bool(conflicts)
        status = "PASS" if got == want else "FAIL"
        if got != want:
            ok = False
        print(f"  {status}  {label:<30} -> {'conflict raised' if got else 'merged cleanly'}"
              f"   (expected {'conflict' if want else 'clean'})")
    print("\n  self-test " + ("PASS — the conflict path fires, and cosmetic\n"
          "  formatting does NOT raise a false conflict." if ok else "FAILED"))
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true",
                    help="negative-control the conflict detection and exit")
    ap.add_argument("--package", required=False, help="e.g. pulseengine:falcon-cascade@0.7.0")
    ap.add_argument("--out", required=False)
    ap.add_argument("components", nargs="*")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if not a.package or not a.out or not a.components:
        ap.error("--package, --out and components are required unless --self-test")

    types: dict[str, tuple[str, str]] = {}   # name -> (body, source artifact)
    ifaces: dict[str, tuple[str, str]] = {}
    conflicts: list[str] = []

    def put(store, name, body, src, kind):
        if name in store:
            prev, psrc = store[name]
            if norm(prev) != norm(body):
                conflicts.append(
                    f"{kind} '{name}' differs between {psrc} and {src}:\n"
                    f"    {psrc}: {norm(prev)[:160]}\n    {src}: {norm(body)[:160]}")
            return
        store[name] = (body, src)

    for art in a.components:
        body = extract(art, a.package)
        if not body:
            print(f"  note: {art} carries no {a.package} — skipped", file=sys.stderr)
            continue
        for m in re.finditer(r'^interface (\w[\w-]*) \{\n(.*?)^\}', body, re.S | re.M):
            name, inner = m.group(1), m.group(2)
            if name == "types":
                for t in re.finditer(
                        r'^  (record|variant|enum|flags|type) ([a-z][a-z0-9-]*)[^\n]*\{?\n?.*?^  \}',
                        inner, re.S | re.M):
                    put(types, t.group(2), t.group(0), art, t.group(1))
            else:
                put(ifaces, name, m.group(0), art, "interface")

    if conflicts:
        print(f"error: {len(conflicts)} conflicting definition(s) — refusing to merge.\n"
              "A silently-resolved conflict is data loss, not a build error.\n",
              file=sys.stderr)
        for c in conflicts:
            print("  " + c, file=sys.stderr)
        return 1

    parts = [f"package {a.package};", ""]
    if types:
        parts.append("interface types {")
        parts.append("\n\n".join(b for b, _ in types.values()))
        parts.append("}")
        parts.append("")
    parts.extend(b for b, _ in ifaces.values())
    open(a.out, "w").write("\n".join(parts).rstrip() + "\n")

    print(f"  merged {len(a.components)} component(s) -> {a.out}")
    print(f"    types:      {', '.join(sorted(types))}")
    print(f"    interfaces: {', '.join(sorted(ifaces))}")
    dup = "none"
    print(f"    conflicts:  {dup}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
