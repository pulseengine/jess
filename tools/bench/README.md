# The shared bench

## `with-device` is a DIRECTORY now, not a script — read this before resolving that path

`tools/bench/with-device` used to be an executable Python script. Since 2026-09-05 it is a
**Rust crate directory** (`Cargo.toml`, `src/`, `tests/`). The path did not change; what lives
at it did.

**The trap, reported by gale on gale#356 after it cost them a debugging session:**

```sh
sib=".../jess/tools/bench/with-device"
[ -x "$sib" ] && exec "$sib" ...      # TRUE for any traversable DIRECTORY
```

`test -x` succeeds on a directory you can `cd` into, so a resolver written the obvious way
selects the directory, and the failure surfaces later as `permission denied` / **exit 126** —
an error nowhere near its cause.

**Resolve it like this instead:**

```sh
[ -f "$cand" ] && [ -x "$cand" ]      # -f first: a directory is not a candidate
```

## What to use instead

Consume the **released binary**, not a path inside this repo:

```
release:pulseengine/jess@v0.7.1!with-device-0.2.1-<triple>.tar.gz!with-device
```

Assets are cosign-signed (`SHA256SUMS.txt` + `.cosign.bundle`) with SLSA build provenance —
verify the signature before trusting the checksums:

```sh
cosign verify-blob \
  --certificate-identity-regexp 'https://github.com/pulseengine/jess/\.github/workflows/release\.yml@.*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  --bundle SHA256SUMS.txt.cosign.bundle SHA256SUMS.txt
sha256sum -c SHA256SUMS.txt
```

Building from this directory (`cargo build --release`) is fine for development; it is not what
another repo should pin.

## Catalogue vs registry

`hardware-catalog.yaml` is **what we support** — part identity, capabilities and the surprises,
each fact citing the artifact that measured it. True of the *part*, not of our bench, and the half
that must not diverge between agents: a device-name disagreement is what makes a lock vacuous.

The registries below are **what is present here** — which unit, which tty, which host. They differ
per host by design.

`check-catalog.sh` asserts every registry name resolves in the catalogue and every provenance
citation exists, and carries negative controls for both. It runs in CI. Intended future: the
catalogue becomes a digest-pinned varve layer payload so both agents consume identical bytes by
construction rather than by copying (varve#130).

## The device registry is authoritative, and it is HOST-LOCAL

A claim only means something on the machine the hardware is plugged into, so each host has its
own registry:

| host | registry | devices |
|---|---|---|
| this repo (Mac) | `tools/bench/devices.yaml` | `stlink-v3` (NUCLEO-G474RE), `pixhawk-6xrt`, `selftest-device` |
| `fourpi` (Pi 4) | `~/.config/pulseengine/bench-devices.yaml` — **host-local, deliberately not committed** | `pixhawk-6xrt`, `stlink-v1` (STM32VLDISCOVERY), `selftest-device` |

**Use the registered name exactly.** An unregistered name is refused (exit 2) rather than
silently given its own lock file — gale hit this immediately, having invented
`stlink-v1-f100` where the registry says `stlink-v1`. Under the old prototype those were two
different locks: both agents would have claimed successfully, neither excluding the other, and
the bench would have looked protected while being completely unguarded.

## Prove you hold the claim

`with-device` exports `WITH_DEVICE_CLAIM` into the wrapped command, so a script can assert its
own precondition instead of trusting that someone remembered:

```sh
with-device --require-claim pixhawk-6xrt   # exits 2, with what to do, if not held
```

## Why the Pi's registry is not committed

There used to be a copy at `tools/bench/devices-fourpi.yaml`, described as "for review". It had
already drifted from the live file by the time anyone checked:

```
Pi live registry   55d7a1d6...
committed copy     f627c2f4...
```

A hand-copied mirror of a live file is a claim that decays silently — the same defect class as a
README asserting a control the scripts do not implement. Deleted rather than re-synced, because
re-syncing only resets the clock on the same failure.

The direction this is heading (see varve#130): split **what hardware we support** — part facts,
quirks, canonical device names, the half that must not diverge between agents — from **what is
deployed here** — which unit, which tty, which serial. The first belongs in a shared,
digest-pinned artifact both agents consume by construction; the second is host-local, changes
whenever a cable moves, and has no business in a public repo.

Until that lands, the live file on each host is the single source for that host, and this
directory carries no copy of it.
