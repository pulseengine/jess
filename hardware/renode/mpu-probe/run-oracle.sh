#!/usr/bin/env bash
# TEST-PIX-036 — does the emulated Cortex-M ENFORCE the MPU? Measured on TWO platforms,
# one of which is Renode's OWN MPU-test platform.
#
# WHY. gale#348: gale's verified MPU primitive cannot ship as a wasm artifact because
# enforcement is a PRIVILEGED PPB REGISTER WRITE. If it ships, jess receives the verified
# region-table computation and THE REGISTER WRITE BECOMES JESS'S OBLIGATION. Before building
# to that, jess needs to know whether the obligation can be VALIDATED in emulation.
#
# PROBE DESIGN. With PRIVDEFENA=0 a single data region is not enough: instruction fetch, the
# stack and the markers must all sit inside a grant, or the probe faults on its own
# bookkeeping instead of the access under test. The first version of this got that wrong.
# So: grant CODE and DATA, leave a HOLE granted to nobody, write into the hole.
#
# THE SECOND HALF IS THE POINT. Renode ships tests/unit-tests/mpu.robot, which runs four
# Zephyr memory-protection suites on stm32f4_discovery-kit and requires PROJECT EXECUTION
# SUCCESSFUL. That suite PASSES on the same platform where this probe shows an ungranted
# write landing. So the suite does not detect absent enforcement — which is why "Renode has
# MPU tests and they pass" is not evidence that the MPU works.
#
# CHARACTERIZATION TEST, NOT A GATE ON JESS'S CODE: it asserts today's behaviour and FAILS
# LOUDLY if enforcement ever appears, because that is good news jess must act on.
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
build rt "-mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard" \
   "-DCODE_BASE=0x00000000 -DCODE_SZ=18 -DDATA_BASE=0x20000000 -DDATA_SZ=14 -DHOLE_ADDR=0x2000C000 -DMARK=0x20000100" rt1176.ld
build f4 "-mcpu=cortex-m4 -mfloat-abi=soft" \
   "-DCODE_BASE=0x08000000 -DCODE_SZ=19 -DDATA_BASE=0x20000000 -DDATA_SZ=14 -DHOLE_ADDR=0x2000C000 -DMARK=0x20000100" stm32f4.ld

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

check() { # $1 name  $2 elf  $3 repl
  local W; W=( $(probe "$2" "$3" "$1") )
  [ "${#W[@]}" -eq 5 ] || fail "$1: expected 5 words, got ${#W[@]} (see $OUT/$1.log)"
  local TYPE="${W[0]}" GRANTED="${W[1]}" HOLE="${W[2]}" CFSR="${W[3]}" STEP="${W[4]}"
  printf '  %-12s TYPE %s  granted %s  hole %s  CFSR %s  STEP %s\n' "$1" "$TYPE" "$GRANTED" "$HOLE" "$CFSR" "$STEP"
  # Distinguish "no MPU modelled" from "modelled but inert" — different facts.
  [ "$TYPE" != "0x00000000" ] || fail "$1: MPU_TYPE reports ZERO regions; cannot tell 'not enforced' from 'not present'"
  [ "$GRANTED" = "0x1111AAAA" ] || fail "$1: the GRANTED store did not land ($GRANTED) — the probe itself is broken, not the MPU"
  [ "$STEP" != "0x1E55DEAD" ] || fail "$1: escalated to HardFault — code or stack fell outside a grant, so this measures the probe, not enforcement"
  if [ "$STEP" = "0x1E55FA17" ]; then
    fail "$1: MPU ENFORCEMENT IS NOW PRESENT (CFSR $CFSR). That is GOOD NEWS and a CHANGE — the gale#348 register-write obligation just became testable in emulation. Update TEST-PIX-036 and AFD-077."
  fi
  [ "$STEP" = "0xBADF0011" ] || fail "$1: unexpected STEP $STEP — investigate before trusting any MPU result here"
  [ "$HOLE" = "0x2222BBBB" ] || fail "$1: the ungranted write neither faulted nor landed ($HOLE) — unexpected third behaviour"
  [ "$CFSR" = "0x00000000" ] || fail "$1: no fault taken yet CFSR is $CFSR — inconsistent"
}

echo "== MPU enforcement, two platforms =="
check rt1176-m7  rt "$ROOT/hardware/renode/pixhawk6xrt.repl"
check stm32f4    f4 "platforms/boards/stm32f4_discovery-kit.repl"

echo
echo "Result: PASS (characterization) — neither platform ENFORCES the MPU. Both advertise 8"
echo "        regions, accept the configuration, and let a write into an ungranted hole land."
echo "        stm32f4_discovery-kit is Renode's OWN platform for tests/unit-tests/mpu.robot,"
echo "        whose four Zephyr memory-protection suites PASS on it — so that suite does not"
echo "        detect absent enforcement. jess CANNOT validate the gale#348 register-write"
echo "        obligation in emulation; that leg requires silicon."
