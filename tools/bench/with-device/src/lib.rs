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

use std::collections::BTreeSet;
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

pub const USAGE: &str = "\
with-device — hold exclusive claims on shared bench hardware while a command runs.

usage:
  with-device <device>... [--purpose <text>] [--wait <s>] -- <command>...
  with-device --status [--format json]
  with-device --self-test
  with-device --version | -V
  with-device --help | -h

options:
  --purpose <text>   why you are claiming it (shown to whoever gets refused)
  --wait <seconds>   block up to N seconds instead of failing fast (deadlock-free)
  --registry <path>  device registry (default: $BENCH_REGISTRY, then standard paths)
  --format json      machine-readable output for --status

environment:
  BENCH_WHO          name recorded as the holder (e.g. jess, gale)
  BENCH_LOCKDIR      lock directory (default /var/tmp/pulseengine-bench)
  BENCH_REGISTRY     device registry path

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
    Status { json: bool },
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

/// Device names out of a registry document. Deliberately a 20-line reader for the one shape
/// this file has, not a YAML implementation — a dependency here would have to be audited
/// inside a signed layer for no gain.
///
/// A device is a key indented exactly two spaces under `devices:`. Anything deeper is one of
/// that device's attributes and MUST NOT be mistaken for a device: `with-device what` would
/// otherwise take a lock that excludes nobody, which is the exact failure AFD-082 recorded.
pub fn parse_registry(text: &str) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    let mut in_devices = false;
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
                names.insert(name.to_string());
            }
        }
    }
    names
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
pub fn registry(explicit: Option<&str>) -> Result<BTreeSet<String>, String> {
    let candidates = registry_search_path(explicit);
    for c in &candidates {
        if let Ok(mut f) = File::open(c) {
            let mut s = String::new();
            if f.read_to_string(&mut s).is_err() {
                continue;
            }
            let names = parse_registry(&s);
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

    // ── the search path ─────────────────────────────────────────────────────────────────

    #[test]
    fn explicit_registry_wins_and_is_the_only_candidate() {
        let p = registry_search_path(Some("/x/y.yaml"));
        assert_eq!(p, vec![PathBuf::from("/x/y.yaml")]);
    }
}
