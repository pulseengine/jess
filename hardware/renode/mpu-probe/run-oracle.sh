#!/usr/bin/env bash
# TEST-PIX-036 — WHICH MPU accesses does the emulated Cortex-M enforce?
#
# WHY. gale#348: gale's verified MPU primitive cannot ship as a wasm artifact because
# enforcement is a PRIVILEGED PPB REGISTER WRITE. If it ships, jess receives the verified
# region-table computation and THE REGISTER WRITE BECOMES JESS'S OBLIGATION. So jess needs
# to know what can be validated in emulation.
#
# THE ANSWER IS NOT "nothing", AND JESS GOT THIS WRONG ONCE (AFD-076, AFD-077 — both
# corrected by AFD-078). Renode DOES enforce the v7-M MPU. A first probe ran PRIVILEGED,
# saw an out-of-grant write land, and concluded no enforcement. gale caught it. Measured:
#
#   PRIVILEGED   background access -> LANDS   CFSR 0          (the real, narrow gap)
#   UNPRIVILEGED background access -> DENIED  CFSR 0x82       (DACCVIOL+MMARVALID)
#
# The gap is exactly PRIVILEGED BACKGROUND accesses — an address matching no enabled
# region — which Renode grants as if PRIVDEFENA were permanently 1. Region permissions and
# XN ARE enforced, including for privileged code (gale reproduced Renode's own
# tests/unit-tests/mpu.robot: 4 suites, real faults, zassert_unreachable controls untripped).
#
# CONSEQUENCE, and it is the useful one: jess CAN validate the register-write obligation in
# emulation PROVIDED THE TENANT RUNS UNPRIVILEGED — which is the correct configuration for
# isolation anyway, and is exactly what gale's security-containment caveat asks for.
#
# CHARACTERIZATION TEST, NOT A GATE ON JESS'S CODE: it pins BOTH behaviours and fails if
# EITHER changes, because either change is something jess must act on.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$D/../../.." && pwd)"
RENODE="${RENODE:-/Users/r/renode-1.16.1/Contents/MacOS/renode}"
RENODE_DIR="$(dirname "$RENODE")"
OUT="${OUT:-$ROOT/.scratch/mpu-probe}"; mkdir -p "$OUT"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -x "$RENODE" ] || { echo "SKIP: renode not at $RENODE" >&2; exit 2; }
command -v arm-none-eabi-gcc >/dev/null || fail "arm-none-eabi-gcc not on PATH"

build() { # $1 out  $2 cpuflags  $3 defines  $4 ldscript
  # shellcheck disable=SC2086
  arm-none-eabi-gcc -c -x assembler-with-cpp $2 $3 "$D/mpu.S" -o "$OUT/$1.o" || fail "assemble $1"
  arm-none-eabi-ld -T "$D/$4" "$OUT/$1.o" -o "$OUT/$1.elf" || fail "link $1"
}
RTDEF="-DCODE_BASE=0x00000000 -DCODE_SZ=18 -DDATA_BASE=0x20000000 -DDATA_SZ=14 -DHOLE_ADDR=0x2000C000 -DMARK=0x20000100"
F4DEF="-DCODE_BASE=0x08000000 -DCODE_SZ=19 -DDATA_BASE=0x20000000 -DDATA_SZ=14 -DHOLE_ADDR=0x2000C000 -DMARK=0x20000100"
build rt_priv   "-mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard" "$RTDEF"          rt1176.ld
build rt_unpriv "-mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard" "$RTDEF -DUNPRIV" rt1176.ld
build f4_priv   "-mcpu=cortex-m4 -mfloat-abi=soft"                "$F4DEF"          stm32f4.ld
build f4_unpriv "-mcpu=cortex-m4 -mfloat-abi=soft"                "$F4DEF -DUNPRIV" stm32f4.ld

probe() { # $1 elf  $2 repl  $3 name -> echoes 5 words
  local rd; rd="$(mktemp -d)"
  cat > "$rd/p.resc" <<EOF
using sysbus
mach create "$3"
machine LoadPlatformDescription @$2
sysbus LoadELF @$OUT/$1.elf
emulation RunFor "0.1"
pause
echo "B"
sysbus ReadDoubleWord 0x20000100
sysbus ReadDoubleWord 0x20000104
sysbus ReadDoubleWord 0x20000108
sysbus ReadDoubleWord 0x2000010C
sysbus ReadDoubleWord 0x20000110
echo "E"
EOF
  # Renode ends monitor lines with \r\r\n, so /^B$/ never matches unqualified — an
  # unstripped parse silently yields ZERO words while the log plainly holds five.
  ( cd "$RENODE_DIR" && "$RENODE" --console --disable-xwt -e "include @$rd/p.resc
quit" 2>&1 ) | perl -pe 's/\e\[[0-9;]*m//g' | tr -d '\r' > "$OUT/$3.log"
  rm -rf "$rd"
  awk '/^B$/{f=1;next} /^E$/{f=0} f' "$OUT/$3.log" | grep -E '^0x'
}

check() { # $1 name  $2 elf  $3 repl  $4 expect: "grant" | "deny"
  local W; W=( $(probe "$2" "$3" "$1") )
  [ "${#W[@]}" -eq 5 ] || fail "$1: expected 5 words, got ${#W[@]} (see $OUT/$1.log)"
  local TYPE="${W[0]}" GRANTED="${W[1]}" HOLE="${W[2]}" CFSR="${W[3]}" STEP="${W[4]}"
  printf '  %-18s TYPE %s  granted %s  hole %s  CFSR %s  STEP %s\n' "$1" "$TYPE" "$GRANTED" "$HOLE" "$CFSR" "$STEP"
  [ "$TYPE" != "0x00000000" ] || fail "$1: MPU_TYPE reports ZERO regions; cannot tell 'not enforced' from 'not present'"
  [ "$GRANTED" = "0x1111AAAA" ] || fail "$1: the GRANTED store did not land ($GRANTED) — the probe is broken, not the MPU"
  [ "$STEP" != "0x1E55DEAD" ] || fail "$1: escalated to HardFault — code or stack fell outside a grant, so this measures the probe"
  case "$4" in
    deny)
      [ "$STEP" = "0x1E55FA17" ] || fail "$1: UNPRIVILEGED background access was NOT denied (STEP $STEP). Renode previously enforced this; if it stopped, jess's plan to validate the gale#348 obligation in emulation is void — investigate before relying on it."
      [ "$CFSR" = "0x00000082" ] || fail "$1: denied, but CFSR is $CFSR not 0x82 (DACCVIOL+MMARVALID) — different fault than expected"
      ;;
    grant)
      if [ "$STEP" = "0x1E55FA17" ]; then
        fail "$1: PRIVILEGED background access is NOW DENIED (CFSR $CFSR). That is a CHANGE and GOOD NEWS — Renode has stopped treating PRIVDEFENA as permanently 1. Update TEST-PIX-036 and AFD-078."
      fi
      [ "$STEP" = "0xBADF0011" ] || fail "$1: unexpected STEP $STEP"
      [ "$HOLE" = "0x2222BBBB" ] || fail "$1: privileged background write neither faulted nor landed ($HOLE)"
      [ "$CFSR" = "0x00000000" ] || fail "$1: no fault taken yet CFSR is $CFSR"
      ;;
  esac
}

echo "== MPU enforcement: two platforms x two privilege levels =="
RTREPL="$ROOT/hardware/renode/pixhawk6xrt.repl"
F4REPL="platforms/boards/stm32f4_discovery-kit.repl"
check rt-priv    rt_priv   "$RTREPL" grant
check rt-unpriv  rt_unpriv "$RTREPL" deny
check f4-priv    f4_priv   "$F4REPL" grant
check f4-unpriv  f4_unpriv "$F4REPL" deny

echo
echo "Result: PASS (characterization) — Renode ENFORCES the v7-M MPU for UNPRIVILEGED"
echo "        background accesses (denied, CFSR 0x82 DACCVIOL+MMARVALID) and GRANTS them"
echo "        for PRIVILEGED ones, i.e. it treats PRIVDEFENA as permanently 1. That single"
echo "        gap is what an earlier jess probe mistook for 'no MPU enforcement' (AFD-076,"
echo "        AFD-077 — corrected by AFD-078)."
echo "        So the gale#348 register-write obligation IS validatable in emulation, provided"
echo "        the tenant runs UNPRIVILEGED — which is the right configuration regardless."
