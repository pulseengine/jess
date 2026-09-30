#!/usr/bin/env bash
# Two things about ci.yml that only CI has ever told us, each after a wasted round-trip.
#
# WHY (both mine, both in the same week):
#   AFD-124  a new step omitted `working-directory: jess`, which every other run-step in that
#            job declares because the repo is checked out into a subdirectory. bash reported
#            "No such file or directory" and exited 127, and the job surfaced it as a failure of
#            "rivet validate (artifact spine)" — a gate that never started, wearing the name of
#            one that did.
#   AFD-125  inserting a step after `name:`/`run:` spliced it BETWEEN a step's `run:` and its
#            `env:` block. The new step inherited `RENODE`, the soak oracle lost it, and
#            run-soak-oracle.sh SKIPped with exit 2 looking for a macOS path on a linux runner.
#            The anchor was two lines; the step was four.
#
# Both are statically decidable from the workflow, so decide them here instead of in a runner.
#
#   1. SCRIPT REACHABILITY — every repo-relative script a run-step invokes must exist at the
#      path that step would resolve it from, given its effective working-directory.
#   2. RENODE — every step invoking a Renode oracle must have RENODE in its effective env
#      (step, then job, then workflow). Without it the oracle SKIPs with exit 2 rather than
#      running, which is "could not run" reported as a failure.
#
# Negative-controlled in --self-test: both must be observed to FAIL on injected input.
set -uo pipefail
cd "$(dirname "$0")/../.."
WF="${WF:-.github/workflows/ci.yml}"

run_check() {
  python3 - "$1" "${2:-.}" <<'PY'
import os, re, sys, yaml
wf, root = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(wf))
wf_env = d.get('env') or {}

# A repo-relative script invocation: tools/..., hardware/..., app/..., scripts/... with a
# script-ish extension. Deliberately narrow — the point is paths we can CHECK, not every token.
SCRIPT = re.compile(r'(?<![\w./-])((?:tools|hardware|app|scripts)/[\w./-]+\.(?:sh|py))')
RENODE_ORACLE = re.compile(r'(run-oracle|run-soak-oracle|run-ekf-oracle|measure-stack)\.sh')

bad_path, bad_renode, checked_paths, checked_renode = [], [], 0, 0
for jn, j in (d.get('jobs') or {}).items():
    j_env = j.get('env') or {}
    j_wd = ((j.get('defaults') or {}).get('run') or {}).get('working-directory')
    # WHERE THE REPO ACTUALLY IS in this job's workspace. `actions/checkout` with `path: jess`
    # puts the repo root at <workspace>/jess, so a step whose working-directory is `jess` is AT
    # the repo root — not at repo_root/jess. Modelling this is what makes AFD-124's bug
    # detectable rather than a false alarm: that step had NO working-directory, so it ran at the
    # workspace root, OUTSIDE the checkout, where tools/ does not exist.
    ckout = ''
    for st in j.get('steps') or []:
        if 'actions/checkout' in str(st.get('uses', '')):
            ckout = ((st.get('with') or {}).get('path') or '').strip('/')
            break
    for st in j.get('steps') or []:
        if 'run' not in st:
            continue
        run = str(st['run'])
        wd = (st.get('working-directory') or j_wd or '.').strip('/')
        if wd == '.':
            wd = ''
        label = st.get('name') or run.splitlines()[0][:50]

        # The step's cwd expressed RELATIVE TO THE REPO ROOT. None means the step runs outside
        # the checkout entirely, so nothing in the repo is reachable from it.
        if not ckout:
            rel_dir = wd
        elif wd == ckout:
            rel_dir = ''
        elif wd.startswith(ckout + '/'):
            rel_dir = wd[len(ckout) + 1:]
        else:
            rel_dir = None

        # 1. script reachability
        for rel in set(SCRIPT.findall(run)):
            checked_paths += 1
            if rel_dir is None:
                bad_path.append((jn, label, wd or '<workspace root>', rel,
                                 f"runs OUTSIDE the checkout (repo is at {ckout!r})"))
            elif not os.path.isfile(os.path.join(root, rel_dir, rel)):
                bad_path.append((jn, label, wd or '<workspace root>', rel, "does not exist"))

        # 2. RENODE for the emulator oracles
        if RENODE_ORACLE.search(run):
            checked_renode += 1
            env = {**wf_env, **j_env, **(st.get('env') or {})}
            if 'RENODE' not in env:
                bad_renode.append((jn, label))

# REFUSE a vacuous pass: a run that checked nothing says nothing.
if checked_paths == 0:
    print("  REFUSING: found NO repo-relative script invocations — this check would be vacuous")
    sys.exit(2)

fail = 0
if bad_path:
    print(f"  UNREACHABLE SCRIPT ({len(bad_path)}):")
    for jn, label, wd, rel, why in bad_path:
        print(f"    {jn}: {label}")
        print(f"      working-directory={wd!r} -> {rel}: {why}")
    print( "      A step that cannot find its script exits 127 and reads as a gate that FAILED")
    print( "      rather than one that never ran. Add `working-directory:` or fix the path.")
    fail = 1
else:
    print(f"  scripts: {checked_paths} repo-relative invocation(s) all resolve from their step's cwd")

if bad_renode:
    print(f"  MISSING RENODE ({len(bad_renode)}):")
    for jn, label in bad_renode:
        print(f"    {jn}: {label}")
    print( "      Without RENODE the oracle SKIPs with exit 2, looking for a macOS path on a")
    print( "      linux runner — 'could not run' surfacing as a failure.")
    fail = 1
elif checked_renode:
    print(f"  renode: {checked_renode} oracle step(s) all carry RENODE in their effective env")

sys.exit(fail)
PY
}

if [ "${1:-}" = "--self-test" ]; then
  echo "== negative controls: both assertions must be observed to FAIL =="
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  mkdir -p "$t/.github/workflows" "$t/tools/real"
  printf 'echo hi\n' > "$t/tools/real/present.sh"

  # NC1 — a step whose script does not resolve from its working-directory.
  cat > "$t/.github/workflows/nc1.yml" <<'Y'
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: reachable
        run: tools/real/present.sh
      - name: wrong cwd
        working-directory: somewhere-else
        run: tools/real/present.sh
Y
  if run_check "$t/.github/workflows/nc1.yml" "$t" >/dev/null 2>&1; then
    echo "  NC1 FAILED: an unreachable script path was not caught"; exit 1
  fi
  echo "  NC1 ok: a script that does not resolve from its step's cwd is refused"

  # NC2 — a Renode oracle step with no RENODE anywhere in its effective env.
  mkdir -p "$t/hardware/renode/cascade-invoke"
  printf 'echo hi\n' > "$t/hardware/renode/cascade-invoke/run-soak-oracle.sh"
  cat > "$t/.github/workflows/nc2.yml" <<'Y'
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: soak without RENODE
        run: hardware/renode/cascade-invoke/run-soak-oracle.sh
Y
  if run_check "$t/.github/workflows/nc2.yml" "$t" >/dev/null 2>&1; then
    echo "  NC2 FAILED: a Renode oracle step with no RENODE was not caught"; exit 1
  fi
  echo "  NC2 ok: a Renode oracle step missing RENODE is refused"

  # NC3 — the vacuity refusal: nothing to check is not a pass.
  cat > "$t/.github/workflows/nc3.yml" <<'Y'
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo nothing to check here
Y
  run_check "$t/.github/workflows/nc3.yml" "$t" >/dev/null 2>&1
  [ $? -eq 0 ] && { echo "  NC3 FAILED: reported success having checked nothing"; exit 1; }
  echo "  NC3 ok: finding no script invocations is a refusal, not a pass"

  # And the RENODE rule must ACCEPT the inherited forms, or it would be a false alarm machine.
  cat > "$t/.github/workflows/ok.yml" <<'Y'
on: push
env:
  RENODE: /tmp/renode/renode
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: soak with workflow-level RENODE
        run: hardware/renode/cascade-invoke/run-soak-oracle.sh
Y
  run_check "$t/.github/workflows/ok.yml" "$t" >/dev/null 2>&1 \
    || { echo "  NC4 FAILED: a workflow-level RENODE was not honoured — the rule would misfire"; exit 1; }
  echo "  NC4 ok: RENODE inherited from the workflow env is accepted"
  echo "== the real thing =="
fi

run_check "$WF" "."
rc=$?
[ "$rc" -eq 0 ] && echo "WORKFLOW OK — every script resolves from its step's cwd, every Renode step has RENODE." \
                || echo "WORKFLOW FAIL"
exit $rc
