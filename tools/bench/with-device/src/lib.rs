//! with-device — hold exclusive claims on shared bench hardware while a command runs.
//!
//! WHY IT EXISTS. Two agents (jess and gale) share one physical bench. The failure that
//! matters is not "both want it" — it is a SILENT collision: two processes driving one debug
//! probe, or two readers on one tty each receiving a SUBSET of the stream with no error on
//! either side. Measured on a real Pixhawk: one reader 66,872 B in 5 s; two readers together
//! 37,787 + 40,053 = 77,840 B, i.e. each got about half and neither noticed. That is
//! indistinguishable from a flaky USB link, which makes it the worst kind of evidence to
//! have in a safety campaign.
//!
//! WHY A LOCK AND NOT A RESERVATION RECORD. The claim is an OS flock(2) on an open fd, held
//! for exactly the lifetime of the wrapped command. When the holder dies — crash, kill,
//! panic — the kernel drops it. There is no release step to forget, no stale-lock reaper.
//!
//! HOW DEADLOCK IS PREVENTED — two independent mechanisms, and it is worth being precise
//! about which one carries the weight, because they are not equally load-bearing.
//!
//!   (a) NO HOLD-AND-WAIT. On contention, every lock acquired so far is DROPPED before
//!       retrying. Coffman's hold-and-wait condition is broken, so no cycle can exist at
//!       all. This also means a blocked claimant never pins a device it is not using.
//!   (b) SORTED ACQUISITION. Names are sorted before acquisition, so all claimants take
//!       locks in one global order (Dijkstra's resource hierarchy). This makes the fast
//!       path cycle-free without relying on (a) at all.
//!
//! MEASURED, not asserted. `--self-test` races two processes asking for the same two devices
//! in OPPOSITE order. Negative controls run against this binary:
//!
//! | variant                       | opposite-order pair | reading                          |
//! |-------------------------------|---------------------|----------------------------------|
//! | as shipped                    | 0,0 in 2.1 s        | pass                             |
//! | sort removed, (a) intact      | 0,0 in 2.1 s        | test does NOT see the sort go    |
//! | sort removed AND (a) removed  | 3,3 in 15.1 s       | real cycle; only --wait broke it |
//!
//! So the self-test discriminates on (a), NOT on (b). Do not read a green self-test as
//! evidence that the sort works; it is evidence that hold-and-wait is absent. (b) is kept
//! as defence in depth and is what would still hold if `--wait` ever grew a blocking
//! flock(LOCK_EX) path, where dropping-and-retrying is no longer available.

//!
//! TESTING. `--self-test` is the FIELD acceptance check: it ships in the binary and runs on a
//! machine that has no source tree, which is the only kind of check gale or a Pi can run. It
//! is not the test suite. The suite is `cargo test` — unit tests over the pure logic in this
//! module and behavioural tests in `tests/` that spawn the real binary. The split matters
//! because the self-test can only exercise paths it happens to walk; a regression in argument
//! parsing or registry parsing can leave it perfectly green.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{create_dir_all, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub const PROG: &str = "with-device";

// flock(2) — same on macOS and Linux. Declared here so the crate has zero dependencies.
extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}
const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;

/// Exit codes. Callers branch on these, so they are part of the interface, not an
/// implementation detail: `2` usage, `3` busy, otherwise the wrapped command's own status.
pub const EXIT_USAGE: i32 = 2;
pub const EXIT_BUSY: i32 = 3;

/// Name of the environment variable a claim exports into the wrapped command: the
/// comma-separated, sorted list of devices held for the lifetime of that command.
///
/// WHY IT EXISTS. "Always run it under with-device" is a rule that has to be REMEMBERED, and
/// on 2026-09-05 jess broke it five times in one session — every time while chasing a bug,
/// which is exactly when attention is elsewhere. A rule that fails under pressure needs to be
/// checkable rather than promised. With this exported, any script can assert its own
/// precondition (`with-device --require-claim <dev>`) and a script that touches hardware
/// without a claim fails loudly instead of silently racing another agent.
pub const CLAIM_ENV: &str = "WITH_DEVICE_CLAIM";

/// The claim list a wrapped command should see: everything already claimed by an outer
/// with-device, unioned with what this invocation adds. Union rather than overwrite, so that
/// `with-device a -- with-device b -- cmd` leaves `cmd` able to assert either.
pub fn claim_env_value(inherited: Option<&str>, newly: &[String]) -> String {
    let mut set: BTreeSet<String> = inherited
        .unwrap_or("")
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect();
    set.extend(newly.iter().cloned());
    set.into_iter().collect::<Vec<_>>().join(",")
}

/// Devices the current process can prove are claimed, from the environment.
pub fn current_claims() -> BTreeSet<String> {
    std::env::var(CLAIM_ENV)
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

pub const USAGE: &str = "\
with-device — hold exclusive claims on shared bench hardware while a command runs.

usage:
  with-device <device>... [--purpose <text>] [--wait <s>] -- <command>...
  with-device --status [--format json]
  with-device --require-claim <device>...
  with-device --self-test
  with-device --version | -V
  with-device --help | -h

options:
  --purpose <text>   why you are claiming it (shown to whoever gets refused)
  --wait <seconds>   block up to N seconds instead of failing fast (deadlock-free)
  --registry <path>  device registry (default: $BENCH_REGISTRY, then standard paths)
  --format json      machine-readable output for --status
  --require-claim    assert this process is ALREADY inside a claim on those devices; exits 2
                     if not. Put it at the top of any script that touches the hardware, so
                     a forgotten claim fails loudly instead of racing silently.

environment:
  BENCH_WHO          name recorded as the holder (e.g. jess, gale)
  BENCH_LOCKDIR      lock directory (default /var/tmp/pulseengine-bench)
  BENCH_REGISTRY     device registry path
  WITH_DEVICE_CLAIM  set BY with-device for the wrapped command: the sorted, comma-separated
                     devices held for its lifetime. Read it, do not set it yourself.

exit codes:
  0   the wrapped command's status, or success for --status/--self-test
  2   usage error: unknown flag, bad arguments, or an unregistered device name
  3   a device is already claimed; NOTHING was run
NOTE: the wrapped command's status passes through unchanged, so a 2 or 3 may come from it.

Several devices are claimed in sorted order, and a blocked claimant releases what it already
holds rather than waiting on it. Deadlock is impossible regardless of the order you list them.
";

// ─────────────────────────────────────────────────────────────────────────────────────────
// Argument parsing — pure, so it is testable without spawning anything. It used to live
// inline in main() where nothing but the self-test could reach it.
// ─────────────────────────────────────────────────────────────────────────────────────────

#[derive(Debug, PartialEq, Eq)]
pub enum Mode {
    Help,
    Version,
    SelfTest,
    Status {
        json: bool,
    },
    /// Assert that the caller is already inside a claim on these devices. For scripts that
    /// touch hardware to fail loudly rather than race silently.
    RequireClaim(Vec<String>),
    Run(RunArgs),
}

#[derive(Debug, PartialEq, Eq, Default)]
pub struct RunArgs {
    pub devices: Vec<String>,
    pub purpose: String,
    pub wait_s: u64,
    pub registry: Option<String>,
    pub command: Vec<String>,
}

/// Parse argv (without argv[0]). `Err` is a usage message; the caller exits [`EXIT_USAGE`].
///
/// SPLIT ON `--` FIRST. Mode flags are looked for ONLY in the head, never in the wrapped
/// command. Scanning the whole argv meant `with-device probe -- mytool --version` printed
/// with-device's own version, exited 0, and never ran mytool — success reported for a command
/// that did not execute, which is precisely the silent failure this tool exists to prevent.
/// Same for `-h`, `-V`, `--status` and `--self-test` anywhere in the command. Everything after
/// `--` belongs to the command and is never interpreted here.
pub fn parse_args(argv: &[String]) -> Result<Mode, String> {
    let sep = argv.iter().position(|a| a == "--");
    let head = match sep {
        Some(i) => &argv[..i],
        None => argv,
    };
    if head.iter().any(|a| a == "--help" || a == "-h") {
        return Ok(Mode::Help);
    }
    if head.iter().any(|a| a == "--version" || a == "-V") {
        return Ok(Mode::Version);
    }
    if head.iter().any(|a| a == "--self-test") {
        return Ok(Mode::SelfTest);
    }
    if let Some(i) = head.iter().position(|a| a == "--require-claim") {
        let devs: Vec<String> = head[i + 1..]
            .iter()
            .take_while(|a| !a.starts_with('-'))
            .cloned()
            .collect();
        if devs.is_empty() {
            return Err(format!(
                "{PROG}: --require-claim needs at least one device name"
            ));
        }
        return Ok(Mode::RequireClaim(devs));
    }
    if head.iter().any(|a| a == "--status") {
        let json = head
            .windows(2)
            .any(|w| w[0] == "--format" && w[1] == "json");
        return Ok(Mode::Status { json });
    }
    let sep = sep.ok_or_else(|| format!("{PROG}: missing `--` before the command"))?;
    let (head, tail) = argv.split_at(sep);
    let command: Vec<String> = tail[1..].to_vec();
    if command.is_empty() {
        return Err(format!("{PROG}: no command after `--`"));
    }

    let mut a = RunArgs {
        purpose: "(unstated)".into(),
        ..Default::default()
    };
    a.command = command;
    let mut i = 0;
    while i < head.len() {
        match head[i].as_str() {
            // A flag that takes a value must ERROR when the value is missing rather than
            // silently taking a default: `--wait` with no number used to parse as 0, turning
            // a request to block into a request to fail fast. That is a wrong answer, not a
            // usage error the operator would ever see.
            "--purpose" => {
                i += 1;
                a.purpose = head
                    .get(i)
                    .cloned()
                    .ok_or_else(|| format!("{PROG}: --purpose needs a value"))?;
            }
            "--wait" => {
                i += 1;
                let v = head
                    .get(i)
                    .ok_or_else(|| format!("{PROG}: --wait needs a value in seconds"))?;
                a.wait_s = v
                    .parse()
                    .map_err(|_| format!("{PROG}: --wait wants whole seconds, got '{v}'"))?;
            }
            "--registry" => {
                i += 1;
                a.registry = Some(
                    head.get(i)
                        .cloned()
                        .ok_or_else(|| format!("{PROG}: --registry needs a path"))?,
                );
            }
            "--format" => {
                i += 1;
                let v = head
                    .get(i)
                    .ok_or_else(|| format!("{PROG}: --format needs a value"))?;
                if v != "json" {
                    return Err(format!(
                        "{PROG}: --format only understands 'json', got '{v}'"
                    ));
                }
            }
            s if s.starts_with('-') => return Err(format!("{PROG}: unknown option '{s}'")),
            s => a.devices.push(s.to_string()),
        }
        i += 1;
    }
    if a.devices.is_empty() {
        return Err(format!("{PROG}: no device named"));
    }
    Ok(Mode::Run(a))
}

// ─────────────────────────────────────────────────────────────────────────────────────────
// Registry — the set of device names a claim may name at all.
// ─────────────────────────────────────────────────────────────────────────────────────────

/// Device names out of a registry document, mapping EVERY acceptable name to the CANONICAL one.
/// Deliberately a small reader for the one shape this file has, not a YAML implementation — a
/// dependency here would have to be audited inside a signed layer for no gain.
///
/// A device is a key indented exactly two spaces under `devices:`. Anything deeper is one of
/// that device's attributes and MUST NOT be mistaken for a device: `with-device what` would
/// otherwise take a lock that excludes nobody, which is the exact failure AFD-082 recorded.
///
/// WHY ALIASES EXIST (jess#266). The lock key is the device NAME — `{name}.lock` under
/// `BENCH_LOCKDIR`. So renaming a device is not a cosmetic change: while one agent uses the old
/// name and another the new one, they take DIFFERENT flocks and neither excludes the other. That
/// is the vacuous lock, reached by doing the right thing. An alias resolves to the canonical name
/// BEFORE the lock path is formed, so both names contend for one file and the rename is safe.
///
/// Accepted forms, both measured in the tests:
///     aliases: [old-name, older-name]
///     aliases:
///       - old-name
///
/// COLLISIONS ARE REFUSED, NOT RESOLVED. An alias that equals another device's canonical name, or
/// two devices claiming one alias, would make a lock ambiguous — the failure this is here to
/// prevent. Returning an error is the only safe answer; picking a winner silently is not.
pub fn parse_registry_map(text: &str) -> Result<BTreeMap<String, String>, String> {
    let mut canon: BTreeSet<String> = BTreeSet::new();
    // alias -> (canonical, is_canonical_itself)
    let mut map: BTreeMap<String, String> = BTreeMap::new();
    let mut pending: Vec<(String, String)> = Vec::new(); // (alias, canonical)
    let mut in_devices = false;
    let mut current: Option<String> = None;
    let mut in_alias_block = false;

    let add_alias = |a: &str, dev: &str, pending: &mut Vec<(String, String)>| {
        let a = a.trim().trim_matches('"').trim_matches('\'').trim();
        if !a.is_empty() {
            pending.push((a.to_string(), dev.to_string()));
        }
    };

    for raw in text.lines() {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        let bare = line.split('#').next().unwrap_or("");
        if !in_devices {
            if bare.trim_end() == "devices:" && !bare.starts_with([' ', '\t']) {
                in_devices = true;
            }
            continue;
        }
        if bare.trim().is_empty() {
            continue;
        }
        // A non-indented line ends the block — the next top-level key.
        if !bare.starts_with([' ', '\t']) {
            break;
        }
        let t = bare.trim_end();
        if t.starts_with("  ") && !t.starts_with("   ") && t.ends_with(':') {
            let name = t.trim().trim_end_matches(':').trim();
            if !name.is_empty() {
                canon.insert(name.to_string());
                current = Some(name.to_string());
            }
            in_alias_block = false;
            continue;
        }
        // Inside a device's attributes.
        let Some(dev) = current.clone() else { continue };
        let a = t.trim();
        if in_alias_block {
            if let Some(item) = a.strip_prefix("- ") {
                add_alias(item, &dev, &mut pending);
                continue;
            }
            in_alias_block = false;
        }
        if let Some(rest) = a.strip_prefix("aliases:") {
            let rest = rest.trim();
            if rest.is_empty() {
                in_alias_block = true;
            } else if let Some(inner) = rest.strip_prefix('[').and_then(|r| r.strip_suffix(']')) {
                for item in inner.split(',') {
                    add_alias(item, &dev, &mut pending);
                }
            } else {
                // A scalar `aliases: foo` — accept the single name rather than ignore it. An
                // alias silently dropped is an alias that takes its own lock.
                add_alias(rest, &dev, &mut pending);
            }
        }
    }

    for c in &canon {
        map.insert(c.clone(), c.clone());
    }
    for (alias, dev) in pending {
        if canon.contains(&alias) && alias != dev {
            return Err(format!(
                "registry is ambiguous: '{alias}' is an alias of '{dev}' AND a device in its own \
right. One name would then mean two devices, so the lock it takes is ambiguous. Refusing."
            ));
        }
        if let Some(prev) = map.get(&alias) {
            if prev != &dev {
                return Err(format!(
                    "registry is ambiguous: alias '{alias}' is claimed by both '{prev}' and \
'{dev}'. Refusing rather than picking one — the lock would exclude the wrong agent."
                ));
            }
        }
        map.insert(alias, dev);
    }
    Ok(map)
}

/// Canonical device names only. Aliases are deliberately absent: this is the set a human is shown
/// and the set a registry declares, not the set a caller may type.
pub fn parse_registry(text: &str) -> BTreeSet<String> {
    match parse_registry_map(text) {
        Ok(m) => m
            .iter()
            .filter(|(k, v)| k == v)
            .map(|(k, _)| k.clone())
            .collect(),
        Err(_) => BTreeSet::new(),
    }
}

/// Paths searched for a registry, in order, when `--registry` is absent.
pub fn registry_search_path(explicit: Option<&str>) -> Vec<PathBuf> {
    if let Some(p) = explicit {
        return vec![p.into()];
    }
    if let Ok(p) = std::env::var("BENCH_REGISTRY") {
        return vec![p.into()];
    }
    let mut v: Vec<PathBuf> = vec![
        "bench-devices.yaml".into(),
        "tools/bench/devices.yaml".into(),
    ];
    if let Ok(home) = std::env::var("HOME") {
        v.push(Path::new(&home).join(".config/pulseengine/bench-devices.yaml"));
    }
    v
}

/// FAIL-CLOSED: with no registry we refuse rather than accept any name. An unregistered name
/// creates its OWN lock file and excludes nobody — a lock a typo can bypass is worse than no
/// lock, because both agents then believe they hold the device.
pub fn registry(explicit: Option<&str>) -> Result<BTreeMap<String, String>, String> {
    let candidates = registry_search_path(explicit);
    for c in &candidates {
        if let Ok(mut f) = File::open(c) {
            let mut s = String::new();
            if f.read_to_string(&mut s).is_err() {
                continue;
            }
            // A parse ERROR is not "keep looking". An ambiguous registry is a refusal: falling
            // through to the next candidate would silently run against a different file.
            let names = parse_registry_map(&s)?;
            if !names.is_empty() {
                return Ok(names);
            }
        }
    }
    Err(format!(
        "no device registry found (looked at: {}). Create one or pass --registry. Refusing \
to accept an unvalidated device name: it would create its own lock and exclude nobody.",
        candidates
            .iter()
            .map(|p| p.display().to_string())
            .collect::<Vec<_>>()
            .join(", ")
    ))
}

// ─────────────────────────────────────────────────────────────────────────────────────────
// Claims
// ─────────────────────────────────────────────────────────────────────────────────────────

pub struct Claim {
    _file: File, // holding the fd holds the lock; dropping it releases
    pub device: String,
}

pub fn lockdir() -> PathBuf {
    std::env::var("BENCH_LOCKDIR")
        .unwrap_or_else(|_| "/var/tmp/pulseengine-bench".to_string())
        .into()
}

/// `None` means the device is claimed by someone else, or the lock file could not be opened.
/// There is deliberately no error detail: from a caller's point of view "not yours right now"
/// is the whole answer, and the holder record is what says who has it.
pub fn try_claim(dev: &str, purpose: &str, who: &str) -> Option<Claim> {
    let dir = lockdir();
    let _ = create_dir_all(&dir);
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        // truncate(false) is deliberate, not an oversight clippy talked us out of: the lock
        // file is a rendezvous point other processes may already hold open. Truncating it on
        // every claim would be a pointless write race against them. Its CONTENT is unused —
        // the lock lives on the fd, via flock(2).
        .truncate(false)
        .open(dir.join(format!("{dev}.lock")))
        .ok()?;
    if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } != 0 {
        return None;
    }
    if let Ok(mut h) = File::create(dir.join(format!("{dev}.holder"))) {
        let _ = write!(
            h,
            "{{\"who\":\"{}\",\"pid\":{},\"purpose\":\"{}\"}}",
            who.replace('"', "'"),
            std::process::id(),
            purpose.replace('"', "'")
        );
    }
    Some(Claim {
        _file: file,
        device: dev.to_string(),
    })
}

pub fn read_holder(dev: &str) -> String {
    std::fs::read_to_string(lockdir().join(format!("{dev}.holder"))).unwrap_or_else(|_| "{}".into())
}

/// The order devices are actually acquired in: sorted and deduplicated.
///
/// Dedup is not tidiness — `with-device probe probe -- cmd` would otherwise try to flock the
/// same file twice from one process. (On BSD/macOS the second call succeeds, so the bug would
/// be invisible here and appear on Linux.) Sorting gives Dijkstra's resource hierarchy.
pub fn acquisition_order(devs: &[String]) -> Vec<String> {
    let mut v = devs.to_vec();
    v.sort();
    v.dedup();
    v
}

/// Acquire every device. Deadlock-free by (a) dropping the partial set rather than waiting on
/// it, and (b) acquiring in sorted order. See the module header for which one the self-test
/// actually measures — it is (a).
pub fn claim_all(
    devs: &[String],
    purpose: &str,
    who: &str,
    wait_s: u64,
) -> Result<Vec<Claim>, String> {
    let order = acquisition_order(devs);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(wait_s);
    loop {
        let mut held: Vec<Claim> = Vec::new();
        let mut blocked = None;
        for d in &order {
            match try_claim(d, purpose, who) {
                Some(c) => held.push(c),
                None => {
                    blocked = Some(d.clone());
                    break;
                }
            }
        }
        match blocked {
            None => return Ok(held),
            Some(d) => {
                drop(held); // never hold a partial set while waiting
                if wait_s == 0 || std::time::Instant::now() >= deadline {
                    return Err(format!(
                        "DEVICE BUSY: '{}' is claimed — {}\nNothing was run.",
                        d,
                        read_holder(&d)
                    ));
                }
                std::thread::sleep(std::time::Duration::from_millis(150));
            }
        }
    }
}

pub fn release_holder_files(claims: &[Claim]) {
    for c in claims {
        let _ = std::fs::remove_file(lockdir().join(format!("{}.holder", c.device)));
    }
}

/// Render `--status`. Split from I/O so the JSON shape is assertable in a unit test.
pub fn render_status(rows: &[(String, bool, String)], json: bool) -> String {
    if json {
        let body: Vec<String> = rows
            .iter()
            .map(|(d, free, h)| {
                format!(
                    "{{\"device\":\"{}\",\"state\":\"{}\",\"holder\":{}}}",
                    d,
                    if *free { "free" } else { "claimed" },
                    if *free { "null" } else { h }
                )
            })
            .collect();
        format!("{{\"devices\":[{}]}}", body.join(","))
    } else if rows.is_empty() {
        "  no claims".to_string()
    } else {
        rows.iter()
            .map(|(d, free, h)| {
                if *free {
                    format!("  {d:<18} free")
                } else {
                    format!("  {d:<18} CLAIMED {h}")
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

pub fn scan_status() -> Vec<(String, bool, String)> {
    let mut rows = Vec::new();
    if let Ok(rd) = std::fs::read_dir(lockdir()) {
        let mut names: Vec<String> = rd
            .filter_map(|e| e.ok())
            .filter_map(|e| e.file_name().into_string().ok())
            .filter(|n| n.ends_with(".lock"))
            .map(|n| n.trim_end_matches(".lock").to_string())
            .collect();
        names.sort();
        for dev in names {
            let free = try_claim(&dev, "status probe", "status").is_some();
            rows.push((dev.clone(), free, read_holder(&dev)));
        }
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    // ── registry parsing ────────────────────────────────────────────────────────────────

    const REG: &str = "\
version: 1
devices:
  stlink-v3:
    what: a probe
    serial: 003B
  pixhawk-6xrt:
    what: the vehicle
notes:
  not-a-device:
";

    #[test]
    fn reads_device_names() {
        let n = parse_registry(REG);
        assert!(n.contains("stlink-v3"));
        assert!(n.contains("pixhawk-6xrt"));
        assert_eq!(n.len(), 2);
    }

    /// The AFD-082 failure in miniature: an ATTRIBUTE accepted as a device name would take a
    /// lock that excludes nobody, while both agents believe they hold the device.
    #[test]
    fn attributes_are_not_devices() {
        let n = parse_registry(REG);
        assert!(!n.contains("what"));
        assert!(!n.contains("serial"));
    }

    #[test]
    fn stops_at_the_next_top_level_key() {
        assert!(!parse_registry(REG).contains("not-a-device"));
    }

    #[test]
    fn tolerates_crlf_and_comments() {
        let n =
            parse_registry("devices:\r\n  a:\r\n    what: x\r\n  # b: commented out\r\n  c:\r\n");
        assert_eq!(n, ["a".to_string(), "c".to_string()].into_iter().collect());
    }

    #[test]
    fn no_devices_block_yields_nothing() {
        assert!(parse_registry("version: 1\nother:\n  a:\n").is_empty());
        assert!(parse_registry("").is_empty());
    }

    // ── aliases (jess#266) ──────────────────────────────────────────────────────────────

    const ALIASED: &str = "\
devices:
  nucleo-g474re:
    what: board
    aliases: [stlink-v3, old-name]
  nucleo-wb55rg:
    what: board
    aliases:
      - wb55
  pixhawk-6xrt:
    what: the vehicle
";

    /// THE PROPERTY THAT MAKES A RENAME SAFE: the old name and the new one must resolve to ONE
    /// canonical name, because the lock path is derived from it. If they did not, the two agents
    /// mid-rename would take different flocks and neither would exclude the other.
    #[test]
    fn aliases_resolve_to_the_canonical_name() {
        let m = parse_registry_map(ALIASED).unwrap();
        assert_eq!(m["stlink-v3"], "nucleo-g474re");
        assert_eq!(m["old-name"], "nucleo-g474re");
        assert_eq!(m["nucleo-g474re"], "nucleo-g474re");
        assert_eq!(m["wb55"], "nucleo-wb55rg"); // block-list form
        assert_eq!(m["pixhawk-6xrt"], "pixhawk-6xrt");
    }

    /// THE OTHER DIRECTION, and the one a careless canonicaliser gets wrong: distinct boards must
    /// still be distinct. A resolver that collapsed everything to one name would pass the test
    /// above and make every lock exclude every other — vacuous the opposite way.
    #[test]
    fn distinct_devices_stay_distinct() {
        let m = parse_registry_map(ALIASED).unwrap();
        assert_ne!(m["stlink-v3"], m["wb55"]);
        assert_ne!(m["nucleo-g474re"], m["pixhawk-6xrt"]);
        let canon: BTreeSet<&String> = m.values().collect();
        assert_eq!(canon.len(), 3, "three boards, three lock keys");
    }

    /// Aliases are not devices. `parse_registry` is what a human is shown and what the registry
    /// declares; if an alias leaked into it, the error message would advertise a name as a device.
    #[test]
    fn aliases_are_not_canonical_names() {
        let n = parse_registry(ALIASED);
        assert!(n.contains("nucleo-g474re"));
        assert!(!n.contains("stlink-v3"));
        assert_eq!(n.len(), 3);
    }

    /// An alias that is ALSO a device is refused, not resolved. Picking a winner silently would
    /// give one name two meanings, and the lock would exclude the wrong agent.
    #[test]
    fn an_alias_that_is_a_device_is_refused() {
        let r =
            parse_registry_map("devices:\n  a:\n    aliases: [b]\n  b:\n    what: another board\n");
        let e = r.expect_err("an alias colliding with a device name must be refused");
        assert!(
            e.contains("ambiguous"),
            "message must name the problem: {e}"
        );
    }

    /// Two devices claiming one alias is the same failure from the other side.
    #[test]
    fn an_alias_claimed_twice_is_refused() {
        let r = parse_registry_map(
            "devices:\n  a:\n    aliases: [shared]\n  b:\n    aliases: [shared]\n",
        );
        assert!(r.expect_err("must refuse").contains("ambiguous"));
    }

    /// A device may repeat its OWN name as an alias — harmless, and refusing it would be a
    /// gratuitous refusal rather than a caught hazard.
    #[test]
    fn self_alias_is_harmless() {
        let m = parse_registry_map("devices:\n  a:\n    aliases: [a]\n").unwrap();
        assert_eq!(m["a"], "a");
    }

    /// The alias reader must not mistake an attribute for an alias, nor run past its device. This
    /// is `attributes_are_not_devices` for the alias key: the block form is terminated by the next
    /// attribute, not only by the next device.
    #[test]
    fn alias_block_stops_at_the_next_attribute() {
        let m = parse_registry_map(
            "devices:\n  a:\n    aliases:\n      - x\n    what: board\n    serial: 003B\n  b:\n",
        )
        .unwrap();
        assert_eq!(m["x"], "a");
        assert!(!m.contains_key("what"));
        assert!(!m.contains_key("serial"));
        assert!(!m.contains_key("003B"));
        assert_eq!(m.len(), 3); // a, b, x
    }

    /// A registry with no aliases must behave exactly as before — the change is additive.
    #[test]
    fn a_registry_without_aliases_is_unchanged() {
        let m = parse_registry_map(REG).unwrap();
        assert_eq!(m.len(), 2);
        assert!(m.iter().all(|(k, v)| k == v));
    }

    // ── argument parsing ────────────────────────────────────────────────────────────────

    #[test]
    fn parses_a_plain_run() {
        let m = parse_args(&s(&["dev-a", "--purpose", "why", "--", "echo", "hi"])).unwrap();
        let Mode::Run(a) = m else { panic!("not a run") };
        assert_eq!(a.devices, s(&["dev-a"]));
        assert_eq!(a.purpose, "why");
        assert_eq!(a.command, s(&["echo", "hi"]));
        assert_eq!(a.wait_s, 0);
    }

    #[test]
    fn devices_may_be_listed_in_any_order_and_repeat() {
        let Mode::Run(a) = parse_args(&s(&["b", "a", "b", "--", "true"])).unwrap() else {
            panic!()
        };
        assert_eq!(a.devices, s(&["b", "a", "b"]));
        // ...and the ORDER ACTUALLY USED is canonical, which is what makes a cycle impossible
        // and what stops a repeat from self-blocking.
        assert_eq!(acquisition_order(&a.devices), s(&["a", "b"]));
    }

    #[test]
    fn a_flag_missing_its_value_is_a_usage_error_not_a_default() {
        // Regression: `--wait` with no value silently became 0, turning "block until free"
        // into "fail immediately" — a wrong answer rather than a visible error.
        assert!(parse_args(&s(&["d", "--wait", "--", "true"])).is_err());
        assert!(parse_args(&s(&["d", "--wait", "soon", "--", "true"])).is_err());
        assert!(parse_args(&s(&["d", "--registry", "--", "true"])).is_err());
    }

    #[test]
    fn wait_accepts_whole_seconds() {
        let Mode::Run(a) = parse_args(&s(&["d", "--wait", "30", "--", "true"])).unwrap() else {
            panic!()
        };
        assert_eq!(a.wait_s, 30);
    }

    #[test]
    fn unknown_flag_and_missing_pieces_are_usage_errors() {
        assert!(parse_args(&s(&["d", "--nope", "--", "true"])).is_err());
        assert!(parse_args(&s(&["d", "echo", "hi"])).is_err()); // no `--`
        assert!(parse_args(&s(&["d", "--"])).is_err()); // no command
        assert!(parse_args(&s(&["--", "true"])).is_err()); // no device
    }

    /// The bug this caught, shipped in 0.2.0: mode flags were matched across the WHOLE argv,
    /// so a wrapped command containing `-h`, `-V`, `--version`, `--status` or `--self-test`
    /// hijacked the invocation. `with-device probe -- mytool --version` printed with-device's
    /// version and exited 0 WITHOUT RUNNING mytool — a success report for a command that never
    /// executed, which is the exact class of silent failure this tool exists to prevent.
    #[test]
    fn a_flag_after_the_separator_belongs_to_the_command() {
        for flag in [
            "--color",
            "-h",
            "-V",
            "--version",
            "--status",
            "--self-test",
            "--help",
        ] {
            let m = parse_args(&s(&["d", "--", "mytool", flag])).unwrap();
            let Mode::Run(a) = m else {
                panic!("`{flag}` after `--` was treated as a with-device mode flag");
            };
            assert_eq!(
                a.command,
                s(&["mytool", flag]),
                "command mangled by `{flag}`"
            );
            assert_eq!(a.devices, s(&["d"]));
        }
    }

    /// ...while the same flags BEFORE `--` still mean what they always did.
    #[test]
    fn mode_flags_still_work_in_the_head() {
        assert_eq!(parse_args(&s(&["-h", "--", "cmd"])).unwrap(), Mode::Help);
        assert_eq!(parse_args(&s(&["-V", "--", "cmd"])).unwrap(), Mode::Version);
    }

    #[test]
    fn modes_are_recognised() {
        assert_eq!(parse_args(&s(&["--help"])).unwrap(), Mode::Help);
        assert_eq!(parse_args(&s(&["-h"])).unwrap(), Mode::Help);
        assert_eq!(parse_args(&s(&["--version"])).unwrap(), Mode::Version);
        assert_eq!(parse_args(&s(&["-V"])).unwrap(), Mode::Version);
        assert_eq!(parse_args(&s(&["--self-test"])).unwrap(), Mode::SelfTest);
        assert_eq!(
            parse_args(&s(&["--status"])).unwrap(),
            Mode::Status { json: false }
        );
        assert_eq!(
            parse_args(&s(&["--status", "--format", "json"])).unwrap(),
            Mode::Status { json: true }
        );
    }

    #[test]
    fn format_only_understands_json() {
        assert!(parse_args(&s(&["d", "--format", "xml", "--", "true"])).is_err());
    }

    // ── status rendering ────────────────────────────────────────────────────────────────

    #[test]
    fn status_json_shape_is_stable() {
        let rows = vec![
            ("a".to_string(), true, "{}".to_string()),
            ("b".to_string(), false, "{\"who\":\"gale\"}".to_string()),
        ];
        assert_eq!(
            render_status(&rows, true),
            "{\"devices\":[{\"device\":\"a\",\"state\":\"free\",\"holder\":null},\
{\"device\":\"b\",\"state\":\"claimed\",\"holder\":{\"who\":\"gale\"}}]}"
        );
    }

    #[test]
    fn status_human_output_names_the_holder() {
        let rows = vec![("b".to_string(), false, "{\"who\":\"gale\"}".to_string())];
        let out = render_status(&rows, false);
        assert!(out.contains("CLAIMED"));
        assert!(out.contains("gale"));
    }

    #[test]
    fn empty_status_says_so_rather_than_printing_nothing() {
        assert_eq!(render_status(&[], false), "  no claims");
        assert_eq!(render_status(&[], true), "{\"devices\":[]}");
    }

    // ── the claim marker ────────────────────────────────────────────────────────────────

    #[test]
    fn claim_env_is_sorted_deduped_and_unions_with_an_outer_claim() {
        assert_eq!(claim_env_value(None, &s(&["b", "a"])), "a,b");
        assert_eq!(claim_env_value(Some(""), &s(&["a"])), "a");
        // nested with-device must not hide the outer claim from the inner command
        assert_eq!(
            claim_env_value(Some("outer"), &s(&["inner"])),
            "inner,outer"
        );
        assert_eq!(claim_env_value(Some("a,b"), &s(&["b"])), "a,b");
        assert_eq!(claim_env_value(Some(" a , b "), &s(&["c"])), "a,b,c");
    }

    #[test]
    fn require_claim_parses_its_device_list() {
        assert_eq!(
            parse_args(&s(&["--require-claim", "dev-a", "dev-b"])).unwrap(),
            Mode::RequireClaim(s(&["dev-a", "dev-b"]))
        );
        assert!(parse_args(&s(&["--require-claim"])).is_err());
    }

    // ── the search path ─────────────────────────────────────────────────────────────────

    #[test]
    fn explicit_registry_wins_and_is_the_only_candidate() {
        let p = registry_search_path(Some("/x/y.yaml"));
        assert_eq!(p, vec![PathBuf::from("/x/y.yaml")]);
    }
}
