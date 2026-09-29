"""Resolve a falcon cascade export WITHOUT hardcoding the interface version.

falcon v1.139 moved the interface 0.7.0 -> 0.10.0 while every stage signature and record
shape stayed byte-identical (AFD-121). Four tools here had the version baked into the export
name, so the only thing that broke was a string — and it broke as a `KeyError` that the
calling oracle reported as "it REFUSES to emit a vacuous soak", i.e. a crashed generator
rendered as a considered refusal. That is the third "could not run" reported as "answered no"
in this campaign, so the resolution lives in ONE place now.
"""
import re

_VER = re.compile(r'@\d+\.\d+\.\d+#')


def find_export(names, suffix):
    """names: iterable of export names. suffix: e.g. 'rate#tick'. Returns the real name.

    Raises with the available exports listed — a lookup failure must say what IS there, or the
    caller is left guessing at a string."""
    names = list(names)
    for n in names:
        if _VER.sub('#', n).endswith(suffix):
            return n
    cascade = [n for n in names if 'falcon-cascade' in n]
    raise KeyError(
        f"no export matching {suffix!r} (version-agnostic). "
        f"falcon-cascade exports present: {cascade or '<none>'}")


def interface_version(names):
    """The single interface version these exports share, or raise if they disagree."""
    vs = sorted({m.group(0)[1:-1] for n in names if (m := _VER.search(n))})
    if len(vs) != 1:
        raise ValueError(f"exports do not share one interface version: {vs}")
    return vs[0]
