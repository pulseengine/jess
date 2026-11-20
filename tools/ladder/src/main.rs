//! jess-ladder: write jess's ladder result as `north-star-input.O1.json` (pulseengine.eu seam #393,
//! schema_version 1, objective O1).
//!
//! The generator never takes a verdict as input. For rung r0 it re-runs the existing judge
//! (`run-ekf-oracle.sh` in WORDS_DIR + ELF_DIR mode) over a committed evidence directory and
//! records the judge's exit code. The rungs hil, real-drone and flight have no runner yet, so
//! they are written as ran=false, which the O1 guard counts as a failure.
//!
//! Exit codes: 0 file written; 1 `check` found the file invalid; 2 refused (evidence that must
//! not be published, or a judge that could not run), with no file written.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::{SystemTime, UNIX_EPOCH};

const SCHEMA: &str = include_str!("../input.schema.json");
const RUNGS: [&str; 4] = ["r0", "hil", "real-drone", "flight"];
const SILICON: &str = "rt1176-silicon";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let r = match args.first().map(String::as_str) {
        Some("generate") => generate(&args[1..]),
        Some("check") => check_cmd(&args[1..]),
        _ => Err(Refuse(
            "usage: jess-ladder generate --version V --target T --judge PATH --out FILE [--r0 DIR] [--evidence URL]\n       jess-ladder check FILE --target T"
                .into(),
        )),
    };
    match r {
        Ok(code) => code,
        Err(Refuse(m)) => {
            eprintln!("REFUSED: {m}");
            ExitCode::from(2)
        }
    }
}

struct Refuse(String);

fn opt(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

fn need(args: &[String], name: &str) -> Result<String, Refuse> {
    opt(args, name).ok_or_else(|| Refuse(format!("missing {name}")))
}

fn sha256(p: &Path) -> Result<String, Refuse> {
    // sha256sum on linux, shasum on macOS: the same two tools the judge itself uses.
    for (cmd, a) in [("sha256sum", vec![]), ("shasum", vec!["-a", "256"])] {
        if let Ok(o) = Command::new(cmd).args(&a).arg(p).output() {
            if o.status.success() {
                let s = String::from_utf8_lossy(&o.stdout);
                if let Some(h) = s.split_whitespace().next() {
                    return Ok(h.to_string());
                }
            }
        }
    }
    Err(Refuse(format!("could not hash {}", p.display())))
}

/// One fact for r0. Ok(fact) is a result to publish; Err is evidence that must not be published.
fn judge_r0(dir: Option<&Path>, judge: &Path, target: &str, evidence: &str) -> Result<Value, Refuse> {
    let id = format!("{target}/r0");
    let base = |ran: bool, pass: bool, reason: &str| {
        json!({"id": id, "ran": ran, "pass": pass,
               "detail": {"target": target, "rung": "r0", "oracle": "hardware/renode/cascade-invoke/run-ekf-oracle.sh (WORDS_DIR+ELF_DIR)", "reason": reason}})
    };
    let Some(dir) = dir else { return Ok(base(false, false, "no evidence directory given")) };
    if !dir.is_dir() {
        return Ok(base(false, false, &format!("evidence directory {} does not exist", dir.display())));
    }
    if !dir.join("ekf.words").is_file() {
        return Ok(base(false, false, "no capture of the baseline image (ekf.words): not run on the target"));
    }
    // Every capture present must come from silicon and must name the ELF beside it.
    let mut captures = 0;
    let mut origins = Vec::new();
    for e in std::fs::read_dir(dir).map_err(|e| Refuse(format!("{}: {e}", dir.display())))? {
        let p = e.map_err(|e| Refuse(e.to_string()))?.path();
        if p.extension().and_then(|x| x.to_str()) != Some("words") {
            continue;
        }
        captures += 1;
        let text = std::fs::read_to_string(&p).map_err(|e| Refuse(format!("{}: {e}", p.display())))?;
        let mut lines = text.lines();
        let sha = lines.next().and_then(|l| l.strip_prefix("sha256 ")).unwrap_or("");
        let origin = lines.next().and_then(|l| l.strip_prefix("origin ")).unwrap_or("");
        if !origin.starts_with(SILICON) {
            return Err(Refuse(format!(
                "{} has origin '{origin}', not {SILICON}: an emulator or unknown capture cannot fill a silicon rung",
                p.display()
            )));
        }
        let elf = p.with_extension("elf");
        if !elf.is_file() {
            return Err(Refuse(format!("{} has no ELF beside it ({})", p.display(), elf.display())));
        }
        let got = sha256(&elf)?;
        if got != sha {
            return Err(Refuse(format!(
                "{} names sha256 {sha} but {} is {got}: the evidence is not self-consistent",
                p.display(),
                elf.display()
            )));
        }
        origins.push(origin.to_string());
    }
    let out = Command::new(judge)
        .env("WORDS_DIR", dir)
        .env("ELF_DIR", dir)
        .output()
        .map_err(|e| Refuse(format!("judge {} could not start: {e}", judge.display())))?;
    let log = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    let first_fail = log.lines().find(|l| l.starts_with("FAIL:")).unwrap_or("").to_string();
    let pass = match out.status.code() {
        Some(0) if log.lines().any(|l| l.starts_with("Result: PASS")) => true,
        Some(0) => return Err(Refuse("judge exited 0 without a 'Result: PASS' line".into())),
        Some(1) => false,
        c => return Err(Refuse(format!("judge could not run (exit {c:?}); that is not a result:\n{log}"))),
    };
    let mut f = base(true, pass, if pass { "judge passed" } else { &first_fail });
    f["detail"]["captures"] = json!(captures);
    f["detail"]["origins"] = json!(origins);
    f["detail"]["executed_on"] = json!(SILICON);
    if pass {
        f["control_failed_as_expected"] = json!(true);
    } else if first_fail.contains("control") {
        f["control_failed_as_expected"] = json!(false);
    }
    if !evidence.is_empty() {
        f["evidence"] = json!(evidence);
    }
    Ok(f)
}

fn generate(args: &[String]) -> Result<ExitCode, Refuse> {
    let version = need(args, "--version")?;
    let target = need(args, "--target")?;
    let judge = PathBuf::from(need(args, "--judge")?);
    let out = PathBuf::from(need(args, "--out")?);
    let evidence = opt(args, "--evidence").unwrap_or_default();
    let r0 = opt(args, "--r0").map(PathBuf::from);
    let mut facts = vec![judge_r0(r0.as_deref(), &judge, &target, &evidence)?];
    for rung in &RUNGS[1..] {
        facts.push(json!({"id": format!("{target}/{rung}"), "ran": false, "pass": false,
            "detail": {"target": target, "rung": rung, "oracle": "none yet", "reason": "no runner for this rung in this release"}}));
    }
    let doc = json!({
        "schema_version": 1,
        "objective": "O1",
        "repo": "pulseengine/jess",
        "version": version,
        "generated_at": now_rfc3339(),
        "generator": {"tool": "jess-ladder", "version": env!("CARGO_PKG_VERSION")},
        "facts": facts,
        "not_measured": [
            "r0 is the on-target differential, a prerequisite beside the north star's three rungs (DD-029), not one of them",
            "synth's reach, execution match on the shipped ELF and WCET bound: not reported by jess",
            "timing: every on-target result is load-to-RAM over SWD with PX4 halted; no real-time claim",
            "r0 judges only the falcon estimator stage (ekf#estimate); rate and mixer have their own oracles, position and attitude are not invoked on target"
        ]
    });
    validate(&doc, &target).map_err(|e| Refuse(format!("generated file would be invalid: {e}")))?;
    let text = serde_json::to_string_pretty(&doc).unwrap() + "\n";
    std::fs::write(&out, text).map_err(|e| Refuse(format!("{}: {e}", out.display())))?;
    println!("wrote {}", out.display());
    Ok(ExitCode::SUCCESS)
}

/// Schema v1, plus jess's own rule: exactly one fact per rung for the target, no other facts.
fn validate(doc: &Value, target: &str) -> Result<(), String> {
    let schema: Value = serde_json::from_str(SCHEMA).map_err(|e| e.to_string())?;
    let v = jsonschema::validator_for(&schema).map_err(|e| e.to_string())?;
    let errs: Vec<String> = v.iter_errors(doc).map(|e| format!("{} at {}", e, e.instance_path())).collect();
    if !errs.is_empty() {
        return Err(errs.join("; "));
    }
    let mut ids: Vec<String> = doc["facts"].as_array().unwrap().iter().map(|f| f["id"].as_str().unwrap_or("").to_string()).collect();
    ids.sort();
    let mut want: Vec<String> = RUNGS.iter().map(|r| format!("{target}/{r}")).collect();
    want.sort();
    if ids != want {
        return Err(format!("facts {ids:?} are not exactly one per rung {want:?}"));
    }
    for f in doc["facts"].as_array().unwrap() {
        if f["ran"] == json!(false) && f["pass"] == json!(true) {
            return Err(format!("{} passes without having run", f["id"]));
        }
    }
    Ok(())
}

fn check_cmd(args: &[String]) -> Result<ExitCode, Refuse> {
    let file = args.first().ok_or_else(|| Refuse("check needs a FILE".into()))?;
    let target = need(args, "--target")?;
    let text = std::fs::read_to_string(file).map_err(|e| Refuse(format!("{file}: {e}")))?;
    let doc: Value = match serde_json::from_str(&text) {
        Ok(d) => d,
        Err(e) => {
            println!("INVALID: {file} is not JSON: {e}");
            return Ok(ExitCode::from(1));
        }
    };
    // Seam #393 (pulseengine.eu#394): the asset is north-star-input.<objective>.json, and the
    // name and the objective field must agree.
    let base = Path::new(file).file_name().and_then(|n| n.to_str()).unwrap_or("");
    let named = format!("north-star-input.{}.json", doc["objective"].as_str().unwrap_or("?"));
    if base.starts_with("north-star-input") && base != named {
        println!("INVALID: {file}: file name '{base}' does not match its objective (expected '{named}')");
        return Ok(ExitCode::from(1));
    }
    Ok(match validate(&doc, &target) {
        Ok(()) => {
            println!("VALID: {file} ({} facts, schema_version 1)", doc["facts"].as_array().map_or(0, |a| a.len()));
            ExitCode::SUCCESS
        }
        Err(e) => {
            println!("INVALID: {file}: {e}");
            ExitCode::from(1)
        }
    })
}

/// RFC 3339 UTC; honours SOURCE_DATE_EPOCH so a rebuild can reproduce the file.
fn now_rfc3339() -> String {
    let secs = std::env::var("SOURCE_DATE_EPOCH")
        .ok()
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or_else(|| SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() as i64);
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    // Howard Hinnant's civil_from_days.
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}
