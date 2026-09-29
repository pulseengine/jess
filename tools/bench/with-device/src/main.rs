//! Thin CLI over the `with_device` library. All logic worth testing lives in lib.rs so that
//! `cargo test` can reach it; this file is argv in, exit code out.

use std::process::{self, Command, Stdio};
use std::time::{Duration, Instant};
use with_device::*;

/// The FIELD acceptance check — it ships in the binary and runs where there is no source tree
/// (gale's machine, a Pi). It is not the test suite; `cargo test` is. Kept because the people
/// who most need to verify this tool are the ones who cannot build it.
fn self_test() -> i32 {
    let me = std::env::current_exe().unwrap();
    let reg = std::env::temp_dir().join("with-device-selftest.yaml");
    std::fs::write(
        &reg,
        "devices:\n  selftest-a:\n    what: synthetic\n    aliases: [selftest-a-old]\n  selftest-b:\n    what: synthetic\n",
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
        EXIT_BUSY,
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

    // THE DEADLOCK CHECK: same two devices, OPPOSITE order.
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
        EXIT_USAGE,
    );

    let marker = std::env::temp_dir().join(format!("with-device-selftest-held-{}", process::id()));
    let _ = std::fs::remove_file(&marker);
    // 20s is a CEILING, not a wait: the holder is killed explicitly once the probes are done.
    let holder_cmd = format!("touch {}; sleep 20", marker.display());

    // ALIASES (jess#266). Here rather than only in `cargo test` because this is the check gale
    // can run on wohl.local, where the naming agreement actually has to hold and where there is
    // no source tree. BOTH directions, because either alone is vacuous: an alias must be refused
    // while its canonical name is held, and a DIFFERENT device must stay free — a resolver that
    // collapsed every name to one key would pass the first and fail the second.
    let mut holder = Command::new(&me)
        .args([
            "selftest-a",
            "--registry",
            &r,
            "--purpose",
            "alias-holder",
            "--",
            "sh",
            "-c",
            &holder_cmd,
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    // Wait until the holder DEMONSTRABLY holds it. The marker is touched by the wrapped command,
    // which only runs after the claim succeeds, so observing it cannot race the holder.
    //
    // THE TRAP THIS AVOIDS, WHICH COST TWO FLAKY RUNS BEFORE BEING NAMED: the obvious readiness
    // signal is the lock FILE, and it is wrong twice over. `try_claim` opens it with create(true)
    // BEFORE flock(2) decides anything, and it is deliberately never truncated or removed — so it
    // exists both before this holder has acquired and after any previous self-test. Polling it
    // let the PROBE win the lock; the holder was then the one refused, and
    // "alias shares the lock" reported rc=0 while the aliasing it was testing worked perfectly.
    // A guessed `sleep` has the same defect with extra steps. tests/cli.rs `hold()` documents
    // exactly this and I reintroduced it here.
    let t1 = Instant::now();
    while !marker.exists() && t1.elapsed() < Duration::from_secs(20) {
        std::thread::sleep(Duration::from_millis(25));
    }
    if !marker.exists() {
        println!("  alias holder never acquired  FAIL (cannot run the alias checks)");
        ok = false;
    }
    ok &= check(
        "alias shares the lock",
        run(vec![
            "selftest-a-old",
            "--registry",
            &r,
            "--purpose",
            "alias",
            "--",
            "true",
        ]),
        EXIT_BUSY,
    );
    ok &= check(
        "other device stays free",
        run(vec![
            "selftest-b",
            "--registry",
            &r,
            "--purpose",
            "nc",
            "--",
            "true",
        ]),
        0,
    );
    let _ = holder.kill();
    let _ = holder.wait();
    let _ = std::fs::remove_file(&marker);
    println!("  self-test: {}", if ok { "PASS" } else { "FAIL" });
    if ok {
        0
    } else {
        1
    }
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mode = match parse_args(&argv) {
        Ok(m) => m,
        Err(msg) => {
            eprint!("{msg}\n\n{USAGE}");
            std::process::exit(EXIT_USAGE);
        }
    };
    let args = match mode {
        Mode::Help => {
            print!("{USAGE}");
            std::process::exit(0)
        }
        Mode::Version => {
            println!("{PROG} {VERSION}");
            std::process::exit(0)
        }
        Mode::SelfTest => std::process::exit(self_test()),
        Mode::RequireClaim(devs) => {
            let held = current_claims();
            let missing: Vec<&String> = devs.iter().filter(|d| !held.contains(*d)).collect();
            if missing.is_empty() {
                std::process::exit(0);
            }
            eprintln!(
                "{PROG}: NOT UNDER A CLAIM for {}.\n\
This process is not running inside `with-device`, so nothing stops another agent from \
driving the same hardware at the same time — and a collision on a tty is SILENT: both \
readers get a partial stream and neither errors.\n\
Re-run as: with-device {} --purpose '<why>' -- <your command>",
                missing
                    .iter()
                    .map(|s| s.as_str())
                    .collect::<Vec<_>>()
                    .join(", "),
                devs.join(" ")
            );
            std::process::exit(EXIT_USAGE);
        }
        Mode::Status { json } => {
            println!("{}", render_status(&scan_status(), json));
            std::process::exit(0)
        }
        Mode::Run(a) => a,
    };

    let known = match registry(args.registry.as_deref()) {
        Ok(k) => k,
        Err(e) => {
            eprintln!("{PROG}: {e}");
            std::process::exit(EXIT_USAGE);
        }
    };
    // CANONICALISE BEFORE LOCKING. The lock path is derived from the name, so an alias that
    // reached flock() unresolved would take its OWN file and exclude nobody — the rename hazard
    // aliases exist to close (jess#266). Resolve here, once, and SAY SO: a command that silently
    // locks something other than what the operator typed is worse than one that refuses.
    let mut devices: Vec<String> = Vec::with_capacity(args.devices.len());
    for d in &args.devices {
        match known.get(d) {
            None => {
                let mut canon: Vec<&str> = known
                    .iter()
                    .filter(|(k, v)| k == v)
                    .map(|(k, _)| k.as_str())
                    .collect();
                canon.sort_unstable();
                eprintln!(
                    "{PROG}: UNKNOWN DEVICE '{}'. Known: {}\nRefusing: an unregistered name would \
create its own lock and exclude nobody.",
                    d,
                    canon.join(", ")
                );
                std::process::exit(EXIT_USAGE);
            }
            Some(c) => {
                if c != d {
                    eprintln!("{PROG}: '{d}' is an alias for '{c}' — claiming '{c}'.");
                }
                devices.push(c.clone());
            }
        }
    }
    // Deduplicate: two aliases of one device must not be claimed twice. claim_all takes locks in
    // sorted order and a second flock on a file this process already holds SUCCEEDS on both
    // macOS and Linux, so the duplicate would be silently fine here and a latent surprise
    // anywhere the ordering argument is relied on. Collapse it where it is visible.
    devices.sort();
    devices.dedup();
    let who = std::env::var("BENCH_WHO").unwrap_or_else(|_| "unknown".into());
    let claims = match claim_all(&devices, &args.purpose, &who, args.wait_s) {
        Ok(c) => c,
        Err(msg) => {
            eprintln!("{msg}");
            std::process::exit(EXIT_BUSY);
        }
    };
    // Export the claim so the wrapped command can PROVE it is claimed (see CLAIM_ENV). This
    // is what turns "always use with-device" from a rule someone remembers into one a script
    // can assert with `--require-claim`.
    let claimed: Vec<String> = claims.iter().map(|c| c.device.clone()).collect();
    let claim_env = claim_env_value(std::env::var(CLAIM_ENV).ok().as_deref(), &claimed);

    let code = Command::new(&args.command[0])
        .args(&args.command[1..])
        .env(CLAIM_ENV, &claim_env)
        .status()
        .map(|s| s.code().unwrap_or(1))
        .unwrap_or_else(|e| {
            eprintln!("{PROG}: {e}");
            1
        });
    release_holder_files(&claims);
    std::process::exit(code);
}
