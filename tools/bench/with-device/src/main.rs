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

use std::collections::BTreeSet;
use std::fs::{create_dir_all, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const PROG: &str = "with-device";

// flock(2) — same on macOS and Linux. Declared here so the crate has zero dependencies.
extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}
const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;

const USAGE: &str = "\
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

struct Claim {
    _file: File, // holding the fd holds the lock; dropping it releases
    device: String,
}

fn lockdir() -> PathBuf {
    std::env::var("BENCH_LOCKDIR")
        .unwrap_or_else(|_| "/var/tmp/pulseengine-bench".to_string())
        .into()
}

/// Device names from the registry. FAIL-CLOSED: with no registry we refuse rather than
/// accept any name, because an unregistered name creates its own lock file and excludes
/// nobody. A lock a typo can bypass is worse than no lock: both agents then believe they
/// hold the device.
fn registry(explicit: Option<&str>) -> Result<BTreeSet<String>, String> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(p) = explicit {
        candidates.push(p.into());
    } else if let Ok(p) = std::env::var("BENCH_REGISTRY") {
        candidates.push(p.into());
    } else {
        candidates.push("bench-devices.yaml".into());
        candidates.push("tools/bench/devices.yaml".into());
        if let Ok(home) = std::env::var("HOME") {
            candidates.push(Path::new(&home).join(".config/pulseengine/bench-devices.yaml"));
        }
    }
    for c in &candidates {
        if let Ok(mut f) = File::open(c) {
            let mut s = String::new();
            if f.read_to_string(&mut s).is_err() {
                continue;
            }
            let mut names = BTreeSet::new();
            let mut in_devices = false;
            for line in s.lines() {
                if line.starts_with("devices:") {
                    in_devices = true;
                    continue;
                }
                if in_devices {
                    if !line.trim().is_empty() && !line.starts_with(' ') && !line.starts_with('\t')
                    {
                        break;
                    }
                    let t = line.trim_end();
                    if t.starts_with("  ") && !t.starts_with("    ") && t.ends_with(':') {
                        names.insert(t.trim().trim_end_matches(':').to_string());
                    }
                }
            }
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

fn try_claim(dev: &str, purpose: &str, who: &str) -> Result<Claim, ()> {
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
        .map_err(|_| ())?;
    if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } != 0 {
        return Err(());
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
    Ok(Claim {
        _file: file,
        device: dev.to_string(),
    })
}

fn read_holder(dev: &str) -> String {
    std::fs::read_to_string(lockdir().join(format!("{dev}.holder"))).unwrap_or_else(|_| "{}".into())
}

/// Acquire every device. Deadlock-free by (a) dropping the partial set rather than waiting
/// on it, and (b) acquiring in sorted order. See the module header for which one the
/// self-test actually measures.
fn claim_all(devs: &[String], purpose: &str, who: &str, wait_s: u64) -> Result<Vec<Claim>, String> {
    let mut sorted: Vec<String> = devs.to_vec();
    sorted.sort();
    sorted.dedup();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(wait_s);
    loop {
        let mut held: Vec<Claim> = Vec::new();
        let mut blocked = None;
        for d in &sorted {
            match try_claim(d, purpose, who) {
                Ok(c) => held.push(c),
                Err(_) => {
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

fn status(json: bool) -> i32 {
    let dir = lockdir();
    let mut rows: Vec<(String, bool, String)> = Vec::new();
    if let Ok(rd) = std::fs::read_dir(&dir) {
        let mut names: Vec<String> = rd
            .filter_map(|e| e.ok())
            .filter_map(|e| e.file_name().into_string().ok())
            .filter(|n| n.ends_with(".lock"))
            .map(|n| n.trim_end_matches(".lock").to_string())
            .collect();
        names.sort();
        for dev in names {
            let free = try_claim(&dev, "status probe", "status").is_ok();
            rows.push((dev.clone(), free, read_holder(&dev)));
        }
    }
    if json {
        let body: Vec<String> = rows
            .iter()
            .map(|(d, free, h)| {
                format!(
                    "{{\"device\":\"{}\",\"state\":\"{}\",\"holder\":{}}}",
                    d,
                    if *free { "free" } else { "claimed" },
                    if *free { "null".to_string() } else { h.clone() }
                )
            })
            .collect();
        println!("{{\"devices\":[{}]}}", body.join(","));
    } else if rows.is_empty() {
        println!("  no claims");
    } else {
        for (d, free, h) in &rows {
            if *free {
                println!("  {d:<18} free");
            } else {
                println!("  {d:<18} CLAIMED {h}");
            }
        }
    }
    0
}

/// Prove the properties that matter. A lock that does not exclude is worse than none: it
/// gives two agents false confidence while they corrupt each other's session.
fn self_test() -> i32 {
    let me = std::env::current_exe().unwrap();
    let reg = std::env::temp_dir().join("with-device-selftest.yaml");
    std::fs::write(
        &reg,
        "devices:\n  selftest-a:\n    what: synthetic\n  selftest-b:\n    what: synthetic\n",
    )
    .unwrap();
    let r = reg.display().to_string();
    let run = |args: Vec<&str>| -> i32 {
        Command::new(&me)
            .args(&args)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.code().unwrap_or(-1))
            .unwrap_or(-1)
    };
    // Returns the verdict rather than capturing `ok`, so the deadlock check below can also
    // fold into the same accumulator without fighting the borrow checker.
    let check = |label: &str, got: i32, want: i32| -> bool {
        let good = got == want;
        println!(
            "  {label:<28} rc={got} (expect {want}) {}",
            if good { "OK" } else { "FAIL" }
        );
        good
    };
    let mut ok = true;

    let mut holder = Command::new(&me)
        .args([
            "selftest-a",
            "--registry",
            &r,
            "--purpose",
            "hold",
            "--",
            "sleep",
            "3",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    std::thread::sleep(std::time::Duration::from_millis(700));
    ok &= check(
        "contender while held",
        run(vec![
            "selftest-a",
            "--registry",
            &r,
            "--purpose",
            "c",
            "--",
            "true",
        ]),
        3,
    );
    let _ = holder.wait();
    ok &= check(
        "after release",
        run(vec![
            "selftest-a",
            "--registry",
            &r,
            "--purpose",
            "c",
            "--",
            "true",
        ]),
        0,
    );

    let mut crasher = Command::new(&me)
        .args([
            "selftest-a",
            "--registry",
            &r,
            "--purpose",
            "crash",
            "--",
            "sh",
            "-c",
            "kill -9 $$",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let _ = crasher.wait();
    std::thread::sleep(std::time::Duration::from_millis(200));
    ok &= check(
        "after holder CRASHED",
        run(vec![
            "selftest-a",
            "--registry",
            &r,
            "--purpose",
            "c",
            "--",
            "true",
        ]),
        0,
    );

    // THE DEADLOCK TEST: same two devices, OPPOSITE order. Textbook cycle without ordering.
    let t0 = std::time::Instant::now();
    let mut p1 = Command::new(&me)
        .args([
            "selftest-a",
            "selftest-b",
            "--registry",
            &r,
            "--wait",
            "15",
            "--purpose",
            "ab",
            "--",
            "sleep",
            "1",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut p2 = Command::new(&me)
        .args([
            "selftest-b",
            "selftest-a",
            "--registry",
            &r,
            "--wait",
            "15",
            "--purpose",
            "ba",
            "--",
            "sleep",
            "1",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let c1 = p1.wait().map(|s| s.code().unwrap_or(-1)).unwrap_or(-1);
    let c2 = p2.wait().map(|s| s.code().unwrap_or(-1)).unwrap_or(-1);
    let secs = t0.elapsed().as_secs_f32();
    let dl = c1 == 0 && c2 == 0 && secs < 12.0;
    ok &= dl;
    println!(
        "  opposite-order pair          rc={c1},{c2} in {secs:.1}s (expect 0,0 fast) {}",
        if dl { "OK — no deadlock" } else { "FAIL" }
    );

    ok &= check(
        "unregistered device",
        run(vec![
            "selftest-typo",
            "--registry",
            &r,
            "--purpose",
            "c",
            "--",
            "true",
        ]),
        2,
    );
    println!("  self-test: {}", if ok { "PASS" } else { "FAIL" });
    if ok {
        0
    } else {
        1
    }
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.iter().any(|a| a == "--help" || a == "-h") {
        print!("{USAGE}");
        std::process::exit(0);
    }
    if argv.iter().any(|a| a == "--version" || a == "-V") {
        println!("{PROG} {VERSION}");
        std::process::exit(0);
    }
    if argv.iter().any(|a| a == "--self-test") {
        std::process::exit(self_test());
    }
    if argv.iter().any(|a| a == "--status") {
        let json = argv
            .windows(2)
            .any(|w| w[0] == "--format" && w[1] == "json");
        std::process::exit(status(json));
    }
    let sep = match argv.iter().position(|a| a == "--") {
        Some(i) => i,
        None => {
            eprint!("{PROG}: missing `--` before the command\n\n{USAGE}");
            std::process::exit(2);
        }
    };
    let (head, tail) = argv.split_at(sep);
    let cmd = &tail[1..];
    if cmd.is_empty() {
        eprint!("{PROG}: no command after `--`\n\n{USAGE}");
        std::process::exit(2);
    }

    let (mut devices, mut purpose, mut wait_s, mut reg_path) =
        (Vec::new(), String::from("(unstated)"), 0u64, None::<String>);
    let mut i = 0;
    while i < head.len() {
        match head[i].as_str() {
            "--purpose" => {
                i += 1;
                purpose = head.get(i).cloned().unwrap_or_default();
            }
            "--wait" => {
                i += 1;
                wait_s = head.get(i).and_then(|s| s.parse().ok()).unwrap_or(0);
            }
            "--registry" => {
                i += 1;
                reg_path = head.get(i).cloned();
            }
            "--format" => {
                i += 1;
            }
            a if a.starts_with('-') => {
                eprint!("{PROG}: unknown option '{a}'\n\n{USAGE}");
                std::process::exit(2);
            }
            a => devices.push(a.to_string()),
        }
        i += 1;
    }
    if devices.is_empty() {
        eprint!("{PROG}: no device named\n\n{USAGE}");
        std::process::exit(2);
    }

    let known = match registry(reg_path.as_deref()) {
        Ok(k) => k,
        Err(e) => {
            eprintln!("{PROG}: {e}");
            std::process::exit(2);
        }
    };
    for d in &devices {
        if !known.contains(d) {
            eprintln!("{PROG}: UNKNOWN DEVICE '{}'. Known: {}\nRefusing: an unregistered name would create its own lock and exclude nobody.",
                      d, known.iter().cloned().collect::<Vec<_>>().join(", "));
            std::process::exit(2);
        }
    }
    let who = std::env::var("BENCH_WHO").unwrap_or_else(|_| "unknown".into());
    let claims = match claim_all(&devices, &purpose, &who, wait_s) {
        Ok(c) => c,
        Err(msg) => {
            eprintln!("{msg}");
            std::process::exit(3);
        }
    };
    let code = Command::new(&cmd[0])
        .args(&cmd[1..])
        .status()
        .map(|s| s.code().unwrap_or(1))
        .unwrap_or_else(|e| {
            eprintln!("{PROG}: {e}");
            1
        });
    for c in &claims {
        let _ = std::fs::remove_file(lockdir().join(format!("{}.holder", c.device)));
    }
    std::process::exit(code);
}
