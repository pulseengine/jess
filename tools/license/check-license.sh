#!/usr/bin/env bash
# The repository's license claims, enforced rather than stated.
#
# README.md says jess is Apache-2.0 and that "every Rust crate in this repository declares it in
# its Cargo.toml". A sentence like that is true on the day it is written and silently false the
# day someone adds a crate without a `license` field. This campaign has found that exact shape
# repeatedly (AFD-135/136/137/138/139/141): a rule in prose beside nothing that runs it. So the
# claim gets a step.
#
# Asserts:
#   1. LICENSE exists and is the canonical Apache-2.0 text, by digest. It is byte-identical to
#      https://www.apache.org/licenses/LICENSE-2.0.txt and to pulseengine/varve's LICENSE.
#      (The org's other repos carry six textual variants of the same license; jess takes the
#      canonical one rather than any of them.)
#   2. EVERY committed Cargo.toml with a [package] table declares license = "Apache-2.0".
#      The set is derived from `git ls-files`, never from a list typed when this was written.
#
# Exit 0 = both hold.  Exit 1 = a claim is false.  Exit 2 = could not determine (no python
# tomllib, or no manifests found at all — a pass over an empty set is not a pass).
set -uo pipefail
SELFTEST=0; [ "${1:-}" = "--self-test" ] && SELFTEST=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TREE="${TREE:-$ROOT}"     # overridable so a control can point at a variant tree
CANON_SHA="cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"

sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }

python3 -c 'import tomllib' 2>/dev/null || { echo "CANNOT DETERMINE: python3 has no tomllib (needs 3.11+)"; exit 2; }

[ -f "$TREE/LICENSE" ] || { echo "FAIL: no LICENSE file at the repository root"; exit 1; }
got=$(sha256 "$TREE/LICENSE")
[ "$got" = "$CANON_SHA" ] || { echo "FAIL: LICENSE is not the canonical Apache-2.0 text (sha256 $got, expected $CANON_SHA)"; exit 1; }
echo "LICENSE: canonical Apache-2.0 text (sha256 ${got:0:12}…)"

( cd "$TREE" && git ls-files 2>/dev/null || find . -name Cargo.toml -not -path './.git/*' -not -path './.scratch/*' | sed 's|^\./||' ) \
  | grep -E '(^|/)Cargo\.toml$' > /tmp/jess-lic-manifests.$$ || true
TREE="$TREE" python3 - /tmp/jess-lic-manifests.$$ <<'PY'
import sys, os, tomllib
tree=os.environ['TREE']
files=[l.strip() for l in open(sys.argv[1]) if l.strip()]
os.unlink(sys.argv[1])
pkgs=[]; bad=[]; skipped=0
for f in files:
    d=tomllib.load(open(os.path.join(tree,f),'rb'))
    if 'package' not in d: skipped+=1; continue
    pkgs.append(f)
    lic=d['package'].get('license')
    if lic!='Apache-2.0': bad.append((f,lic))
if not pkgs:
    print("CANNOT DETERMINE: no Cargo.toml with a [package] table found — refusing to pass over an empty set")
    sys.exit(2)
print(f"Cargo manifests: {len(pkgs)-len(bad)} of {len(pkgs)} declare license = \"Apache-2.0\""
      + (f" ({skipped} workspace-only manifest(s) without [package], not applicable)" if skipped else ""))
for f,l in bad: print(f"  FAIL {f}: license = {l!r}")
sys.exit(1 if bad else 0)
PY
rc=$?
[ "$rc" -ne 0 ] && exit $rc

if [ "$SELFTEST" = "1" ]; then
  echo; echo "--- controls (each differs from the real tree in EXACTLY ONE variable) ---"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  me="$ROOT/tools/license/check-license.sh"
  mk() { rm -rf "$tmp/t"; mkdir -p "$tmp/t"; cp "$ROOT/LICENSE" "$tmp/t/"; mkdir -p "$tmp/t/a"; cp "$ROOT/tools/bench/with-device/Cargo.toml" "$tmp/t/a/Cargo.toml"; }
  run() { rc=0; TREE="$tmp/t" "$me" >"$tmp/o" 2>&1 || rc=$?; echo $rc; }
  mk; r=$(run); [ "$r" = 0 ] && echo "NC1 a valid tree                     -> PASS (exit 0)  [positive control]" || { echo "NC1 expected 0, got $r"; cat "$tmp/o"; exit 1; }
  mk; sed -i.bak '/^license = /d' "$tmp/t/a/Cargo.toml"; r=$(run); [ "$r" = 1 ] && echo "NC2 a crate with no license field     -> FAIL (exit 1)  [the drift this exists for]" || { echo "NC2 expected 1, got $r"; cat "$tmp/o"; exit 1; }
  mk; sed -i.bak 's/^license = .*/license = "MIT"/' "$tmp/t/a/Cargo.toml"; r=$(run); [ "$r" = 1 ] && echo "NC3 a crate declaring MIT             -> FAIL (exit 1)  [wrong license, not just absent]" || { echo "NC3 expected 1, got $r"; cat "$tmp/o"; exit 1; }
  mk; printf '\n' >> "$tmp/t/LICENSE"; r=$(run); [ "$r" = 1 ] && echo "NC4 LICENSE altered by one byte       -> FAIL (exit 1)  [text is pinned, not just present]" || { echo "NC4 expected 1, got $r"; cat "$tmp/o"; exit 1; }
  mk; rm "$tmp/t/LICENSE"; r=$(run); [ "$r" = 1 ] && echo "NC5 LICENSE missing                   -> FAIL (exit 1)" || { echo "NC5 expected 1, got $r"; cat "$tmp/o"; exit 1; }
  mk; rm "$tmp/t/a/Cargo.toml"; r=$(run); [ "$r" = 2 ] && echo "NC6 no manifests at all               -> CANNOT DETERMINE (exit 2)  [no pass over an empty set]" || { echo "NC6 expected 2, got $r"; cat "$tmp/o"; exit 1; }
  echo "all 6 controls behaved as specified (1 positive, 5 negative)"
fi
