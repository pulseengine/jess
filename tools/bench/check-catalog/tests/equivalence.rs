//! Equivalence harness: the old script is the oracle (port-with-equivalence).
//!
//! Runs tools/bench/check-catalog.ref.sh (the Python implementation, frozen) and
//! tools/bench/check-catalog.sh (this crate's binary) on the same CAT/REG inputs and
//! asserts identical stdout and exit code. Inputs: the real catalogue and registry, named
//! edge cases (including every crash path the port reproduces), and seeded random cases
//! derived from the real catalogue. Fixtures are JSON, which both PyYAML and rivet read
//! with the same types, so a YAML 1.1/1.2 typing difference cannot enter through them.
//!
//! The reference needs python3 with PyYAML on PATH (prefix PATH with EQUIV_PYTHON_DIR to
//! choose one). If it cannot run, the harness FAILS; it never skips.
//!
//! `mutants_are_detected` plants two behaviour changes in a copy of the reference and
//! requires each to break equivalence on these inputs: a harness that cannot fail proves
//! nothing.

use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::process::Command;

const RANDOM_CASES: usize = 150;
const SEED: u64 = 0x6a65_7373_2329_0290;

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..").canonicalize().unwrap()
}

fn path_env() -> String {
    let p = std::env::var("PATH").unwrap_or_default();
    match std::env::var("EQUIV_PYTHON_DIR") {
        Ok(d) if !d.is_empty() => format!("{d}:{p}"),
        _ => p,
    }
}

/// The port under test: this crate's native binary, or, with EQUIV_PORT_BIN set, another runner
/// of the same port (component-run.sh, which runs the wasm32-wasip2 component under wasmtime).
fn port_bin() -> String {
    match std::env::var("EQUIV_PORT_BIN") {
        Ok(b) if !b.is_empty() => b,
        _ => env!("CARGO_BIN_EXE_check-catalog").to_string(),
    }
}

struct Out {
    code: i32,
    stdout: String,
}

fn run(script: &Path, cat: &Path, reg: &Path) -> Out {
    let o = Command::new("bash")
        .arg(script)
        .env("PATH", path_env())
        .env("CAT", cat)
        .env("REG", reg)
        .env("CHECK_CATALOG", port_bin())
        .current_dir(repo())
        .output()
        .expect("run bash");
    Out { code: o.status.code().unwrap_or(-1), stdout: String::from_utf8_lossy(&o.stdout).into_owned() }
}

fn load(p: &Path) -> Value {
    let o = Command::new("rivet").args(["yaml", "to-json"]).arg(p).env("PATH", path_env()).output().unwrap();
    assert!(o.status.success(), "rivet yaml to-json {} failed", p.display());
    serde_json::from_slice(&o.stdout).unwrap()
}

/// xorshift64*: deterministic, no dependency.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
    fn chance(&mut self, pct: u64) -> bool {
        self.next() % 100 < pct
    }
    fn pick<'a, T>(&mut self, v: &'a [T]) -> &'a T {
        &v[self.below(v.len())]
    }
}

fn keys(v: &Value, k: &str) -> Vec<String> {
    v.get(k).and_then(Value::as_object).map(|o| o.keys().cloned().collect()).unwrap_or_default()
}

enum Input {
    Json(Value),
    Text(&'static str),
}

struct Case {
    name: String,
    cat: Input,
    reg: Input,
}

fn cases() -> Vec<Case> {
    let r = repo();
    let cat = load(&r.join("tools/bench/hardware-catalog.yaml"));
    let reg = load(&r.join("tools/bench/devices.yaml"));
    let boards = keys(&cat, "boards");
    let standalone = keys(&cat, "standalone");
    let synthetic = keys(&cat, "synthetic");
    let parts: Vec<String> = keys(&cat, "parts").into_iter().filter(|p| !boards.contains(p)).collect();
    let unknown: Vec<String> = vec!["no-such-board".into(), "ghost-probe".into(), "stlink-v9".into()];
    assert!(!boards.is_empty() && !standalone.is_empty() && !parts.is_empty(), "catalogue sections empty");

    let mut out = vec![];
    let real_cat = || Input::Json(cat.clone());
    out.push(Case { name: "real".into(), cat: real_cat(), reg: Input::Json(reg.clone()) });

    // Named edge cases: the crash paths and the `or {}` fallbacks the port reproduces.
    let e = |n: &str, c: Input, g: Input| Case { name: n.into(), cat: c, reg: g };
    out.push(e("reg-empty-file", real_cat(), Input::Text("")));
    out.push(e("reg-null", real_cat(), Input::Text("null\n")));
    out.push(e("reg-devices-null", real_cat(), Input::Json(json!({"devices": null}))));
    out.push(e("reg-devices-list", real_cat(), Input::Json(json!({"devices": ["a"]}))));
    out.push(e("reg-is-list", real_cat(), Input::Json(json!([1]))));
    out.push(e("reg-invalid-yaml", real_cat(), Input::Text("devices: [\n")));
    out.push(e("cat-null", Input::Text("null\n"), Input::Json(reg.clone())));
    out.push(e("cat-is-list", Input::Json(json!(["boards"])), Input::Json(reg.clone())));
    out.push(e("cat-invalid-yaml", Input::Text("boards: {\n"), Input::Json(reg.clone())));
    let mut c = cat.clone();
    c["parts"][&parts[0]] = Value::Null;
    out.push(e("cat-part-entry-null", Input::Json(c), Input::Json(reg.clone())));
    let mut c = cat.clone();
    c["boards"][&boards[0]]["measured-by"] = json!("AFD-091");
    out.push(e("cat-measured-by-string", Input::Json(c), Input::Json(reg.clone())));
    let mut c = cat.clone();
    c["boards"][&boards[0]]["measured-by"] = json!(["AFD-99999", "AFD-091"]);
    out.push(e("cat-dangling", Input::Json(c), Input::Json(reg.clone())));
    out.push(e(
        "alias-as-string",
        real_cat(),
        Input::Json(json!({"devices": {boards[0].clone(): {"what": "x", "aliases": parts[0].clone()}}})),
    ));
    out.push(e("device-entry-null", real_cat(), Input::Json(json!({"devices": {boards[0].clone(): null}}))));

    // Seeded random cases, derived from the real catalogue.
    let mut rng = Rng(SEED);
    let mut pool: Vec<String> = vec![];
    for (v, w) in [(&boards, 4), (&standalone, 2), (&synthetic, 1), (&parts, 2), (&unknown, 1)] {
        for _ in 0..w {
            pool.extend(v.iter().cloned());
        }
    }
    // parts carried by two boards: the gale#397 shape, so the ambiguity branch is reached
    let mut shared: Vec<(String, Vec<String>)> = vec![];
    for b in &boards {
        for p in cat["boards"][b].get("parts").and_then(Value::as_array).into_iter().flatten() {
            let p = p.as_str().unwrap().to_string();
            match shared.iter_mut().find(|(k, _)| *k == p) {
                Some(s) => s.1.push(b.clone()),
                None => shared.push((p, vec![b.clone()])),
            }
        }
    }
    let carried: Vec<(String, Vec<String>)> = shared.clone();
    for i in 0..RANDOM_CASES {
        let mut c = cat.clone();
        let mut devs = Map::new();
        let n = rng.below(5);
        for _ in 0..n {
            devs.insert(rng.pick(&pool).clone(), json!({"what": "r"}));
        }
        if rng.chance(30) {
            // register the carriers of a carried part, and alias the part on one of them
            let (p, bs) = rng.pick(&carried).clone();
            for b in &bs {
                if rng.chance(70) {
                    devs.insert(b.clone(), json!({"what": "c"}));
                }
            }
            let target = if rng.chance(70) { rng.pick(&bs).clone() } else { rng.pick(&boards).clone() };
            devs.insert(target, json!({"what": "a", "aliases": [p]}));
        }
        let names: Vec<String> = devs.keys().cloned().collect();
        for d in &names {
            if rng.chance(25) {
                let k = rng.below(3);
                let mut al = vec![];
                for _ in 0..k.max(1) {
                    let a = if rng.chance(30) && !names.is_empty() { rng.pick(&names).clone() } else { rng.pick(&pool).clone() };
                    al.push(Value::String(a));
                }
                devs[d] = if k == 0 { json!({"what": "s", "aliases": al[0].clone()}) } else { json!({"what": "l", "aliases": al}) };
            }
        }
        if rng.chance(15) {
            let s = rng.pick(&standalone).clone();
            c["standalone"][&s].as_object_mut().unwrap().shift_remove("serial");
        }
        if rng.chance(15) {
            let b = rng.pick(&boards).clone();
            c["boards"][&b]["measured-by"] = json!(["AFD-99999"]);
        }
        if rng.chance(15) {
            let b = rng.pick(&boards).clone();
            let p = rng.pick(&parts).clone();
            c["boards"][&b]["parts"] = json!([p]);
        }
        if rng.chance(10) {
            let b = rng.pick(&boards).clone();
            c["boards"].as_object_mut().unwrap().shift_remove(&b);
        }
        let reg_v = if rng.chance(5) { json!({}) } else { json!({"devices": devs}) };
        out.push(Case { name: format!("random-{i}"), cat: Input::Json(c), reg: Input::Json(reg_v) });
    }
    out
}

fn write(dir: &Path, name: &str, i: &Input) -> PathBuf {
    let p = dir.join(name);
    match i {
        Input::Json(v) => std::fs::write(&p, serde_json::to_string_pretty(v).unwrap() + "\n").unwrap(),
        Input::Text(t) => std::fs::write(&p, t).unwrap(),
    }
    p
}

fn tmpdir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("check-catalog-equiv-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Compare `reference` with the port over every case; returns (compared, differing names).
fn compare(reference: &Path, cs: &[Case], dir: &Path, stop_at_first: bool) -> (usize, Vec<String>) {
    let port = repo().join("tools/bench/check-catalog.sh");
    let mut tally: Vec<(&str, usize)> = BRANCHES.iter().map(|b| (*b, 0)).collect();
    let mut diff = vec![];
    let mut n = 0;
    for (i, c) in cs.iter().enumerate() {
        let cat = write(dir, &format!("{i}-cat.yaml"), &c.cat);
        let reg = write(dir, &format!("{i}-reg.yaml"), &c.reg);
        let a = run(reference, &cat, &reg);
        let b = run(&port, &cat, &reg);
        n += 1;
        for t in tally.iter_mut() {
            let hit = match t.0 {
                "exit 0" => b.code == 0,
                "exit 1" => b.code == 1,
                "crash (no check line printed)" => b.code == 1 && !b.stdout.contains("  names:") && !b.stdout.contains("UNKNOWN TO"),
                m => b.stdout.contains(m),
            };
            if hit {
                t.1 += 1;
            }
        }
        if a.code != b.code || a.stdout != b.stdout {
            if !stop_at_first {
                eprintln!("DIFFER {}: reference exit {} / port exit {}", c.name, a.code, b.code);
                eprintln!("--- reference\n{}--- port\n{}", a.stdout, b.stdout);
            }
            diff.push(c.name.clone());
            if stop_at_first {
                break;
            }
        }
    }
    if !stop_at_first {
        eprintln!("branch coverage over {n} cases (port output):");
        for (b, k) in &tally {
            eprintln!("  {k:>4}  {b}");
        }
        let unreached: Vec<&str> = tally.iter().filter(|t| t.1 == 0).map(|t| t.0).collect();
        assert!(unreached.is_empty(), "branches no case reached: {unreached:?}");
    }
    (n, diff)
}

/// Every output branch of the check. A branch no case reaches is a branch the harness
/// says nothing about, so the main test fails on one.
const BRANCHES: &[&str] = &[
    "exit 0",
    "exit 1",
    "crash (no check line printed)",
    "CATALOGUE IS EMPTY",
    "REGISTRY HAS NO DEVICES",
    "UNKNOWN TO THE CATALOGUE",
    "registry devices resolve",
    "STANDALONE ENTRY WITH NO SERIAL",
    "A DEVICE IS NAMED AFTER A PART",
    "AND a device in its own right",
    "is claimed by both",
    "A PART CARRIED BY SEVERAL",
    "ALIAS NAMES A PART NO REGISTERED",
    "MISLEADING ALIAS",
    "ALIAS UNKNOWN TO THE CATALOGUE",
    "alias(es) resolve and are unambiguous",
    "aliases: none declared",
    "DANGLING PROVENANCE",
    "cited artifacts all exist",
];

fn reference_can_run() {
    let ok = Command::new("python3")
        .args(["-c", "import yaml"])
        .env("PATH", path_env())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    assert!(ok, "the REFERENCE cannot run: python3 with PyYAML is not on PATH (set EQUIV_PYTHON_DIR). Refusing to report equivalence over nothing.");
}

fn fingerprint() {
    let src = include_str!("../src/main.rs");
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in src.bytes() {
        h = (h ^ b as u64).wrapping_mul(0x0100_0000_01b3);
    }
    eprintln!("port source fingerprint: fnv64 {h:016x} ({} bytes of src/main.rs)", src.len());
    eprintln!("binary under test: {}", port_bin());
}

#[test]
fn port_matches_reference() {
    reference_can_run();
    fingerprint();
    let cs = cases();
    let dir = tmpdir("main");
    let (n, diff) = compare(&repo().join("tools/bench/check-catalog.ref.sh"), &cs, &dir, false);
    let _ = std::fs::remove_dir_all(&dir);
    eprintln!("{} of {n} cases identical (stdout and exit code)", n - diff.len());
    assert_eq!(n, cs.len());
    assert!(diff.is_empty(), "{} of {n} cases differ: {diff:?}", diff.len());
}

#[test]
fn mutants_are_detected() {
    reference_can_run();
    let r = repo();
    let src = std::fs::read_to_string(r.join("tools/bench/check-catalog.ref.sh")).unwrap();
    let mutants = [
        ("carriers > 1 -> > 2", "    if len(carriers) > 1:", "    if len(carriers) > 2:"),
        ("standalone serial rule disabled", "if not (v or {}).get('serial'))", "if False)"),
        ("empty-registry refusal disabled", "if not used:", "if False:"),
    ];
    let cs = cases();
    for (name, from, to) in mutants {
        assert_eq!(src.matches(from).count(), 1, "mutant '{name}': anchor not found exactly once");
        // The copy must sit in tools/bench/: the script cds to "$(dirname "$0")/../..".
        let m = r.join(format!("tools/bench/.check-catalog.mutant-{}.sh", std::process::id()));
        std::fs::write(&m, src.replace(from, to)).unwrap();
        let dir = tmpdir("mutant");
        let (n, diff) = compare(&m, &cs, &dir, true);
        let _ = std::fs::remove_file(&m);
        let _ = std::fs::remove_dir_all(&dir);
        eprintln!("mutant '{name}': {} after {n} case(s)", if diff.is_empty() { "NOT detected" } else { "detected" });
        assert!(!diff.is_empty(), "mutant '{name}' was NOT detected by {n} cases: the harness cannot fail on it");
    }
}
