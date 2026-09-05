//! Thin CLI over the `with_device` library. All logic worth testing lives in lib.rs so that
//! `cargo test` can reach it; this file is argv in, exit code out.

use std::process::{Command, Stdio};
use with_device::*;

/// The FIELD acceptance check — it ships in the binary and runs where there is no source tree
/// (gale's machine, a Pi). It is not the test suite; `cargo test` is. Kept because the people
/// who most need to verify this tool are the ones who cannot build it.
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
    for d in &args.devices {
        if !known.contains(d) {
            eprintln!(
                "{PROG}: UNKNOWN DEVICE '{}'. Known: {}\nRefusing: an unregistered name would \
create its own lock and exclude nobody.",
                d,
                known.iter().cloned().collect::<Vec<_>>().join(", ")
            );
            std::process::exit(EXIT_USAGE);
        }
    }
    let who = std::env::var("BENCH_WHO").unwrap_or_else(|_| "unknown".into());
    let claims = match claim_all(&args.devices, &args.purpose, &who, args.wait_s) {
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
