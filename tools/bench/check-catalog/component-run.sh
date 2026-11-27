#!/usr/bin/env bash
# Run check-catalog as its wasm32-wasip2 component under wasmtime, with the same CLI as the
# native binary, so tools/bench/check-catalog.sh and the equivalence harness can use it
# unchanged (CHECK_CATALOG / EQUIV_PORT_BIN point here).
#
# A component cannot spawn processes, and the native binary spawns rivet twice: `rivet yaml
# to-json <input>` per input file, and `rivet list --format json` for the provenance check. This
# runner does both on the host and hands the component the JSON (CHECK_CATALOG_INPUT=json,
# CHECK_CATALOG_PROVENANCE=<file>). The check logic, every output line and the exit code come
# from the component.
#
# Env: WASMTIME (default wasmtime), CHECK_CATALOG_WASM (default the release component).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
WASMTIME="${WASMTIME:-wasmtime}"
WASM="${CHECK_CATALOG_WASM:-$HERE/target/wasm32-wasip2/release/check-catalog.wasm}"
[ -f "$WASM" ] || { echo "check-catalog component-run: no component at $WASM" >&2; exit 2; }

# Canonical paths only: the component resolves paths inside the preopened tree without following
# a symlinked prefix such as macOS's /var -> /private/var, so every path handed in is physical.
t=$(cd "$(mktemp -d)" && pwd -P) || exit 2
phys() { local d; d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || { printf '%s' "$1"; return; }; printf '%s/%s' "$d" "$(basename "$1")"; }
trap 'rm -rf "$t"' EXIT

# How many leading arguments after the subcommand are inputs read through rivet.
case "${1:-}" in
  check|fixture-alias|fixture-dev-is-part|fixture-alias-ambig) nin=2 ;;
  first-device|fixture-noserial) nin=1 ;;
  *) nin=0 ;;
esac

args=("${1:-}")
envs=(--env CHECK_CATALOG_INPUT=json)
i=0
for a in "${@:2}"; do
  if [ "$i" -lt "$nin" ]; then
    j="$t/in$i.json"
    if ! rivet yaml to-json "$a" >"$j"; then
      echo "check-catalog: \`rivet yaml to-json $a\` refused the file" >&2
      exit 1
    fi
    # The component is given the original name (it appears in messages) and told where its JSON is.
    args+=("$a")
    envs+=(--env "CHECK_CATALOG_JSON_FOR_$i=$a" --env "CHECK_CATALOG_JSON_FILE_$i=$j")
  else
    args+=("$(phys "$a")")
  fi
  i=$((i + 1))
done

if [ "${1:-}" = check ]; then
  if command -v rivet >/dev/null 2>&1; then
    rivet list --format json >"$t/prov.json" 2>/dev/null
    envs+=(--env "CHECK_CATALOG_PROVENANCE=$t/prov.json")
  else
    envs+=(--env CHECK_CATALOG_PROVENANCE=!NotFound)
  fi
fi

# Rust >= 1.100 std imports wasi:cli/exit exit-with-code; wasmtime links it only on request.
flags=()
grep -aq exit-with-code "$WASM" && flags=(-S cli-exit-with-code)

# The whole host filesystem is preopened at the same paths and every path handed in is absolute
# (no "." preopen: with one, Rust std resolved absolute paths against it and found nothing).
exec "$WASMTIME" run ${flags[@]+"${flags[@]}"} --dir /::/ "${envs[@]}" "$WASM" "${args[@]}"
