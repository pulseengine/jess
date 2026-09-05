//! Behavioural tests: spawn the REAL binary, because the properties that matter here are
//! process properties — what the kernel does with an flock when a holder is SIGKILLed, whether
//! a blocked claimant is still holding something else, whether a refused claim ran anything.
//! None of that is observable from inside a unit test.
//!
//! Each test gets its own BENCH_LOCKDIR and its own registry, so they are order-independent
//! and can run in parallel (cargo's default) without claiming each other's devices.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_with-device");

struct Bench {
    dir: PathBuf,
    reg: PathBuf,
}

impl Bench {
    fn new(tag: &str) -> Bench {
        // Shell-safe by construction: this path is interpolated into `sh -c` by `hold`, and
        // an earlier version used `{:?}` of ThreadId — which renders as `ThreadId(12)`. The
        // parentheses are shell syntax, so every holder command died at parse time and the
        // failure surfaced as "holder never acquired", pointing at the tool rather than at
        // the test that broke it.
        static N: AtomicUsize = AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "wd-test-{}-{}-{}",
            tag,
            std::process::id(),
            N.fetch_add(1, Ordering::SeqCst)
        ));
        assert!(
            !dir.to_str()
                .unwrap()
                .contains(['(', ')', ' ', '$', '\'', '"']),
            "test scratch path is not shell-safe: {dir:?}"
        );
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let reg = dir.join("devices.yaml");
        fs::write(
            &reg,
            "devices:\n  dev-a:\n    what: synthetic\n  dev-b:\n    what: synthetic\n  dev-c:\n    what: synthetic\n",
        )
        .unwrap();
        Bench { dir, reg }
    }

    fn cmd(&self) -> Command {
        let mut c = Command::new(BIN);
        c.env("BENCH_LOCKDIR", self.dir.join("locks"))
            .env("BENCH_WHO", "test");
        c
    }

    /// A full invocation with our registry wired in.
    fn run(&self, devices: &[&str], extra: &[&str], command: &[&str]) -> Output {
        let mut c = self.cmd();
        c.args(devices)
            .args(["--registry", self.reg.to_str().unwrap()])
            .args(extra)
            .arg("--")
            .args(command);
        c.output().unwrap()
    }

    /// Spawn a holder and return only once it DEMONSTRABLY holds the lock.
    ///
    /// Polling with a real claim (`run(...) == 3`) looks like the obvious readiness check and
    /// is a race: the probe competes with the holder for the same lock, and when the probe
    /// wins, the holder is the one refused — so the device is never held, the probe never
    /// sees 3, and the test fails for a reason that has nothing to do with the tool. Instead
    /// the holder touches a marker AFTER acquiring; waiting on that observes the state
    /// without perturbing it.
    fn hold(&self, devices: &[&str], purpose: &str, secs: u32) -> std::process::Child {
        let marker = self.dir.join(format!("held-{}", devices.join("-")));
        let _ = fs::remove_file(&marker);
        let child = self.spawn(
            devices,
            &["--purpose", purpose],
            &[
                "sh",
                "-c",
                &format!("touch {}; sleep {}", marker.display(), secs),
            ],
        );
        assert!(
            wait_until(Duration::from_secs(20), || marker.exists()),
            "holder never acquired {devices:?}"
        );
        child
    }

    fn spawn(&self, devices: &[&str], extra: &[&str], command: &[&str]) -> std::process::Child {
        let mut c = self.cmd();
        c.args(devices)
            .args(["--registry", self.reg.to_str().unwrap()])
            .args(extra)
            .arg("--")
            .args(command)
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        c.spawn().unwrap()
    }
}

impl Drop for Bench {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn rc(o: &Output) -> i32 {
    o.status.code().unwrap_or(-1)
}

/// Wait for a predicate rather than sleeping a guessed interval — a fixed sleep is how these
/// tests become flaky on a loaded CI runner.
fn wait_until(timeout: Duration, mut f: impl FnMut() -> bool) -> bool {
    let end = Instant::now() + timeout;
    while Instant::now() < end {
        if f() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    f()
}

// ── the core promise ─────────────────────────────────────────────────────────────────────

#[test]
fn a_free_device_runs_the_command_and_passes_its_exit_code_through() {
    let b = Bench::new("passthrough");
    assert_eq!(rc(&b.run(&["dev-a"], &[], &["true"])), 0);
    assert_eq!(rc(&b.run(&["dev-a"], &[], &["sh", "-c", "exit 42"])), 42);
    let o = b.run(&["dev-a"], &[], &["echo", "hello"]);
    assert_eq!(String::from_utf8_lossy(&o.stdout).trim(), "hello");
}

/// Exit code 3 must mean NOTHING RAN. A refusal that half-ran the command would be worse than
/// no lock at all, so this asserts absence of a side effect rather than just the code.
#[test]
fn a_busy_device_refuses_with_3_and_runs_nothing() {
    let b = Bench::new("busy");
    let marker = b.dir.join("side-effect");
    let mut holder = b.hold(&["dev-a"], "holding", 30);

    let o = b.run(
        &["dev-a"],
        &[],
        &["sh", "-c", &format!("touch {}", marker.display())],
    );
    assert_eq!(rc(&o), 3);
    assert!(
        !marker.exists(),
        "the command ran despite the claim being refused"
    );
    assert!(String::from_utf8_lossy(&o.stderr).contains("Nothing was run"));

    let _ = holder.kill();
    let _ = holder.wait();
}

/// The reason this is an flock and not a reservation file: a holder that dies violently must
/// not leave the bench locked. No reaper, no stale-lock timeout, nothing to remember.
#[test]
fn a_sigkilled_holder_releases_immediately() {
    let b = Bench::new("sigkill");
    let mut victim = b.hold(&["dev-a"], "about to die", 60);
    assert_eq!(
        rc(&b.run(&["dev-a"], &[], &["true"])),
        3,
        "precondition: held"
    );
    victim.kill().unwrap();
    victim.wait().unwrap();
    assert!(
        wait_until(Duration::from_secs(5), || {
            rc(&b.run(&["dev-a"], &[], &["true"])) == 0
        }),
        "device still locked after the holder was SIGKILLed"
    );
}

// ── multi-device ─────────────────────────────────────────────────────────────────────────

/// The property AFD-083 identified as the load-bearing one, and which `--self-test` does NOT
/// check: a claimant blocked on one device must not be sitting on the others meanwhile.
/// Without this, a process waiting on the vehicle would silently pin the debug probe.
#[test]
fn a_blocked_claimant_holds_nothing_while_it_waits() {
    let b = Bench::new("nohold");
    // Someone holds dev-b.
    let mut holder = b.hold(&["dev-b"], "holds b", 4);

    // A second claimant wants a AND b, and is willing to wait.
    let mut waiter = b.spawn(&["dev-a", "dev-b"], &["--wait", "20"], &["true"]);

    // While it waits, dev-a must remain claimable by a third party.
    assert!(
        wait_until(Duration::from_secs(3), || {
            rc(&b.run(&["dev-a"], &[], &["true"])) == 0
        }),
        "the waiting claimant pinned dev-a, which it is not using"
    );

    let _ = holder.wait();
    assert_eq!(waiter.wait().unwrap().code(), Some(0));
}

/// Two processes, the same two devices, opposite order. Under a naive hold-and-wait design
/// this is the textbook cycle.
#[test]
fn opposite_order_claims_do_not_deadlock() {
    let b = Bench::new("deadlock");
    let t0 = Instant::now();
    let mut p1 = b.spawn(&["dev-a", "dev-b"], &["--wait", "20"], &["sleep", "1"]);
    let mut p2 = b.spawn(&["dev-b", "dev-a"], &["--wait", "20"], &["sleep", "1"]);
    let c1 = p1.wait().unwrap().code();
    let c2 = p2.wait().unwrap().code();
    let elapsed = t0.elapsed();
    assert_eq!((c1, c2), (Some(0), Some(0)));
    assert!(
        elapsed < Duration::from_secs(15),
        "took {elapsed:?} — that is the --wait deadline expiring, i.e. a real deadlock that \
timed out rather than one that never formed"
    );
}

/// Naming a device twice must not make a process block on itself.
#[test]
fn a_repeated_device_does_not_self_block() {
    let b = Bench::new("repeat");
    assert_eq!(rc(&b.run(&["dev-a", "dev-a", "dev-a"], &[], &["true"])), 0);
}

/// Claiming several devices is all-or-nothing: if any one is busy, none is held afterwards.
#[test]
fn a_partial_failure_leaves_nothing_claimed() {
    let b = Bench::new("partial");
    let mut holder = b.hold(&["dev-c"], "holds c", 30);
    assert_eq!(rc(&b.run(&["dev-a", "dev-b", "dev-c"], &[], &["true"])), 3);
    // a and b must be untouched by that failed attempt
    assert_eq!(rc(&b.run(&["dev-a"], &[], &["true"])), 0);
    assert_eq!(rc(&b.run(&["dev-b"], &[], &["true"])), 0);
    let _ = holder.kill();
    let _ = holder.wait();
}

// ── --wait ───────────────────────────────────────────────────────────────────────────────

#[test]
fn wait_blocks_then_succeeds_once_the_holder_is_done() {
    let b = Bench::new("wait-ok");
    let mut holder = b.hold(&["dev-a"], "brief holder", 2);
    let t0 = Instant::now();
    let o = b.run(&["dev-a"], &["--wait", "20"], &["true"]);
    assert_eq!(rc(&o), 0);
    assert!(
        t0.elapsed() > Duration::from_millis(200),
        "did not actually wait"
    );
    let _ = holder.wait();
}

#[test]
fn wait_gives_up_with_3_when_the_deadline_passes() {
    let b = Bench::new("wait-timeout");
    let mut holder = b.hold(&["dev-a"], "long holder", 30);
    let t0 = Instant::now();
    assert_eq!(rc(&b.run(&["dev-a"], &["--wait", "1"], &["true"])), 3);
    assert!(t0.elapsed() >= Duration::from_secs(1));
    let _ = holder.kill();
    let _ = holder.wait();
}

// ── the registry is authoritative ────────────────────────────────────────────────────────

/// AFD-082: a typo used to create its own lock file and exclude nobody, leaving both agents
/// believing they held the device.
#[test]
fn an_unregistered_name_is_refused_and_creates_no_lock() {
    let b = Bench::new("typo");
    let o = b.run(&["dev-typo"], &[], &["true"]);
    assert_eq!(rc(&o), 2);
    assert!(String::from_utf8_lossy(&o.stderr).contains("UNKNOWN DEVICE"));
    let stray = b.dir.join("locks").join("dev-typo.lock");
    assert!(!stray.exists(), "a refused name still created {stray:?}");
}

/// An attribute key must not be usable as a device name.
#[test]
fn a_registry_attribute_is_not_a_device() {
    let b = Bench::new("attr");
    assert_eq!(rc(&b.run(&["what"], &[], &["true"])), 2);
}

/// Fail closed. With no registry anywhere, refusing is correct; accepting any name would be a
/// lock that excludes nobody.
#[test]
fn no_registry_at_all_refuses_rather_than_accepting_anything() {
    let b = Bench::new("noreg");
    let empty = b.dir.join("empty");
    fs::create_dir_all(&empty).unwrap();
    let o = b
        .cmd()
        .current_dir(&empty)
        .env("HOME", &empty)
        .env_remove("BENCH_REGISTRY")
        .args(["dev-a", "--", "true"])
        .output()
        .unwrap();
    assert_eq!(rc(&o), 2);
    assert!(String::from_utf8_lossy(&o.stderr).contains("no device registry found"));
}

// ── CLI baseline (pulseengine-cli-conventions) ───────────────────────────────────────────

#[test]
fn version_help_and_unknown_flag_match_the_toolchain_baseline() {
    let v = Command::new(BIN).arg("--version").output().unwrap();
    assert_eq!(rc(&v), 0);
    assert_eq!(
        String::from_utf8_lossy(&v.stdout).trim(),
        format!("with-device {}", env!("CARGO_PKG_VERSION"))
    );
    assert_eq!(rc(&Command::new(BIN).arg("-V").output().unwrap()), 0);
    assert_eq!(rc(&Command::new(BIN).arg("--help").output().unwrap()), 0);
    assert_eq!(rc(&Command::new(BIN).arg("-h").output().unwrap()), 0);

    let u = Command::new(BIN)
        .args(["--nope", "--", "true"])
        .output()
        .unwrap();
    assert_eq!(rc(&u), 2, "unknown flag must exit 2");
    assert!(
        String::from_utf8_lossy(&u.stderr).contains("usage:"),
        "usage goes to stderr"
    );
    assert!(u.stdout.is_empty(), "usage errors must not write to stdout");
}

/// The bug the unit suite caught, asserted end-to-end on the real binary: a wrapped command
/// containing a flag with-device also understands must still RUN. 0.2.0 printed its own
/// version and exited 0 without running anything.
#[test]
fn a_wrapped_command_may_contain_flags_with_device_also_understands() {
    let b = Bench::new("hijack");
    for flag in ["--version", "-V", "-h", "--help", "--status", "--self-test"] {
        // NOT `echo <flag>`: GNU coreutils `echo` interprets `--version` and `--help`
        // ITSELF, so on Linux the assertion failed while passing on macOS, where BSD echo
        // prints the literal. That is a divergence in the test, not the tool — the flag had
        // been passed through correctly and the wrapped program then acted on it. Here the
        // flag arrives as `$1` to `sh`, which no program interprets, so what is asserted is
        // exactly the property under test: with-device did not consume it.
        let o = b.run(
            &["dev-a"],
            &[],
            &["sh", "-c", "printf 'ran:%s' \"$1\"", "sh", flag],
        );
        assert_eq!(rc(&o), 0, "`{flag}` in the command changed the exit code");
        assert_eq!(
            String::from_utf8_lossy(&o.stdout),
            format!("ran:{flag}"),
            "`{flag}` after `--` was interpreted by with-device instead of being passed on"
        );
    }
}

#[test]
fn status_reports_a_live_claim_and_json_is_parseable() {
    let b = Bench::new("status");
    let mut holder = b.hold(&["dev-a"], "a-reason", 30);

    let o = b.cmd().args(["--status"]).output().unwrap();
    let text = String::from_utf8_lossy(&o.stdout).to_string();
    assert!(text.contains("dev-a"));
    assert!(
        text.contains("CLAIMED"),
        "status did not show the live claim: {text}"
    );
    assert!(
        text.contains("a-reason"),
        "status did not name the purpose: {text}"
    );

    let j = b
        .cmd()
        .args(["--status", "--format", "json"])
        .output()
        .unwrap();
    let jt = String::from_utf8_lossy(&j.stdout).to_string();
    assert!(jt.starts_with("{\"devices\":["), "unexpected json: {jt}");
    assert!(
        jt.contains("\"state\":\"claimed\""),
        "unexpected json: {jt}"
    );
    // Balanced braces/brackets is a cheap structural check that needs no json dependency.
    assert_eq!(jt.matches('{').count(), jt.matches('}').count());
    assert_eq!(jt.matches('[').count(), jt.matches(']').count());

    let _ = holder.kill();
    let _ = holder.wait();
}

/// The shipped field check must keep passing — it is what gale and the Pi can run without a
/// source tree. It uses its own registry and the default lock dir, so give it a private one.
#[test]
fn the_shipped_self_test_passes() {
    let dir = std::env::temp_dir().join(format!("wd-selftest-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    let o = Command::new(BIN)
        .arg("--self-test")
        .env("BENCH_LOCKDIR", &dir)
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&o.stdout);
    assert_eq!(rc(&o), 0, "self-test failed:\n{text}");
    assert!(text.contains("self-test: PASS"));
    let _ = fs::remove_dir_all(&dir);
}

/// A claim must not survive the command: the holder file is cleaned up and the device is free.
#[test]
fn the_claim_ends_when_the_command_ends() {
    let b = Bench::new("lifetime");
    assert_eq!(
        rc(&b.run(&["dev-a"], &["--purpose", "brief"], &["true"])),
        0
    );
    let holder = b.dir.join("locks").join("dev-a.holder");
    assert!(
        !Path::new(&holder).exists(),
        "holder record outlived the command"
    );
    assert_eq!(rc(&b.run(&["dev-a"], &[], &["true"])), 0);
}

/// The claim must be PROVABLE by the wrapped command, not merely true.
///
/// This exists because on 2026-09-05 jess touched the shared Pixhawk five times without a
/// claim in one session — every one of them while chasing a bug, which is exactly when
/// nobody is thinking about bench etiquette. A rule that only holds when you remember it is
/// not a control. Exporting the claim lets any script assert its own precondition.
#[test]
fn the_wrapped_command_can_prove_it_is_claimed() {
    let b = Bench::new("claimenv");
    let o = b.run(
        &["dev-b", "dev-a"],
        &[],
        &["sh", "-c", "printf %s \"$WITH_DEVICE_CLAIM\""],
    );
    assert_eq!(rc(&o), 0);
    // sorted and deduped, matching acquisition order — not the order given on the CLI
    assert_eq!(String::from_utf8_lossy(&o.stdout), "dev-a,dev-b");
}

#[test]
fn require_claim_passes_inside_a_claim_and_fails_outside_it() {
    let b = Bench::new("require");
    let me = BIN;

    // Outside any claim: must refuse, and say what to do about it.
    let out = Command::new(me)
        .args(["--require-claim", "dev-a"])
        .env_remove("WITH_DEVICE_CLAIM")
        .output()
        .unwrap();
    assert_eq!(rc(&out), 2, "unclaimed --require-claim must fail");
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("NOT UNDER A CLAIM"),
        "unhelpful message: {err}"
    );
    assert!(
        err.contains("with-device dev-a"),
        "does not say how to fix it: {err}"
    );

    // Inside a claim on the right device: must pass.
    let ok = b.run(&["dev-a"], &[], &[me, "--require-claim", "dev-a"]);
    assert_eq!(rc(&ok), 0, "claimed --require-claim must pass");

    // Inside a claim on a DIFFERENT device: must still refuse. Holding something is not
    // holding the thing you are about to drive.
    let wrong = b.run(&["dev-a"], &[], &[me, "--require-claim", "dev-b"]);
    assert_eq!(
        rc(&wrong),
        2,
        "a claim on the wrong device must not satisfy the assertion"
    );
}

/// Nesting must not hide the outer claim from the inner command, or a script that legitimately
/// wraps another would start failing its own assertion.
#[test]
fn a_nested_claim_unions_rather_than_replaces() {
    let b = Bench::new("nested");
    let o = b.run(
        &["dev-a"],
        &[],
        &[
            BIN,
            "dev-b",
            "--registry",
            b.reg.to_str().unwrap(),
            "--",
            "sh",
            "-c",
            "printf %s \"$WITH_DEVICE_CLAIM\"",
        ],
    );
    assert_eq!(rc(&o), 0);
    assert_eq!(String::from_utf8_lossy(&o.stdout), "dev-a,dev-b");
}
