//! check-catalog: the catalogue/registry agreement check from tools/bench/check-catalog.sh,
//! ported from the Python that script embedded (jess#290).
//!
//! THIS IS A PORT, NOT A REDESIGN. Every stdout line, every exit code and every point at
//! which the Python raised (an uncaught exception is exit 1 with the lines printed so far)
//! is reproduced, because the old script is the oracle: tests/equivalence.rs runs both and
//! compares. Behaviour changes go in a separate change, with the changed script as oracle.
//!
//! YAML is never parsed here. Both files are read through `rivet yaml to-json` (rivet's own
//! parser, org policy on jess#290), which refuses invalid YAML with exit 1. The self-test
//! fixtures are written as JSON, which is YAML, and read back through the same command.
//!
//! Subcommands (called by check-catalog.sh, which keeps the user-facing CLI):
//!   check <catalog> <registry>                     the three assertions (run_check)
//!   first-device <registry>                        NC1: the registry's first device name
//!   fixture-alias <catalog> <registry> <unknown> <collide>  NC3/NC4 fixtures
//!   fixture-dev-is-part <catalog> <registry> <out> NC5 fixture
//!   fixture-alias-ambig <catalog> <registry> <ambig> <one> <wrong>  NC6 fixtures
//!   fixture-noserial <catalog> <out>               NC8 fixture

use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Write;
use std::process::{exit, Command};

/// An uncaught Python exception: the reference printed a traceback on stderr and exited 1.
/// The message names the exception the reference would have raised.
struct Crash(String);
type R<T> = Result<T, Crash>;

fn crash<T>(what: &str) -> R<T> {
    Err(Crash(what.to_string()))
}

// ---- Python value semantics over JSON -------------------------------------------------

fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().map(|f| f != 0.0).unwrap_or(true),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}

/// `x or {}`
fn or_dict(v: &Value) -> Value {
    if truthy(v) { v.clone() } else { Value::Object(Map::new()) }
}

/// `x or []`
fn or_list(v: &Value) -> Value {
    if truthy(v) { v.clone() } else { Value::Array(vec![]) }
}

/// `d.get(key)` — AttributeError on anything that is not a dict.
fn get(v: &Value, key: &str) -> R<Value> {
    match v {
        Value::Object(o) => Ok(o.get(key).cloned().unwrap_or(Value::Null)),
        _ => crash("AttributeError: .get() on a non-mapping"),
    }
}

/// `d.items()` — AttributeError on anything that is not a dict.
fn items(v: &Value) -> R<Vec<(String, Value)>> {
    match v {
        Value::Object(o) => Ok(o.iter().map(|(k, v)| (k.clone(), v.clone())).collect()),
        _ => crash("AttributeError: .items() on a non-mapping"),
    }
}

/// Iterating a value the way `set(x)` / `list(x)` / `set.update(x)` does: a dict yields its
/// keys, a list its elements, a string its characters; a scalar is not iterable (TypeError).
/// A non-string element is outside what this port reproduces (the reference would carry a
/// mixed-type set and might raise later or not); it is refused as a crash, never guessed.
fn iter_names(v: &Value) -> R<Vec<String>> {
    match v {
        Value::Object(o) => Ok(o.keys().cloned().collect()),
        Value::Array(a) => a
            .iter()
            .map(|e| match e {
                Value::String(s) => Ok(s.clone()),
                _ => crash("unsupported: a non-string name (the port reproduces string names only)"),
            })
            .collect(),
        Value::String(s) => Ok(s.chars().map(|c| c.to_string()).collect()),
        _ => crash("TypeError: object is not iterable"),
    }
}

fn set_of(v: &Value) -> R<BTreeSet<String>> {
    Ok(iter_names(v)?.into_iter().collect())
}

/// Python's repr() of a str.
fn py_repr_str(s: &str) -> String {
    let q = if s.contains('\'') && !s.contains('"') { '"' } else { '\'' };
    let mut out = String::new();
    out.push(q);
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c == q => {
                out.push('\\');
                out.push(c)
            }
            c if (c as u32) < 0x20 || c as u32 == 0x7f => out.push_str(&format!("\\x{:02x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push(q);
    out
}

/// Python's repr() of a list of str: `['a', 'b']`.
fn py_list<'a, I: IntoIterator<Item = &'a String>>(it: I) -> String {
    let parts: Vec<String> = it.into_iter().map(|s| py_repr_str(s)).collect();
    format!("[{}]", parts.join(", "))
}

// ---- reading and writing -------------------------------------------------------------

/// Read a YAML file through `rivet yaml to-json`. A missing file, invalid YAML or a refused
/// construct is exit 1 from rivet with the reason on stderr; the reference raised there too.
fn load(path: &str) -> R<Value> {
    // Component mode (wasm32-wasip2 cannot spawn rivet): the caller, component-run.sh, has
    // already converted each input with `rivet yaml to-json` and passes the JSON file instead.
    // `path` stays the name the user gave (it appears in messages); CHECK_CATALOG_JSON_FOR_<i> /
    // CHECK_CATALOG_JSON_FILE_<i> say which converted file holds that input.
    if std::env::var("CHECK_CATALOG_INPUT").as_deref() == Ok("json") {
        let file = (0..8)
            .find(|i| std::env::var(format!("CHECK_CATALOG_JSON_FOR_{i}")).as_deref() == Ok(path))
            .and_then(|i| std::env::var(format!("CHECK_CATALOG_JSON_FILE_{i}")).ok())
            .unwrap_or_else(|| path.to_string());
        let bytes = std::fs::read(&file).map_err(|e| Crash(format!("cannot read {file}: {e}")))?;
        return match serde_json::from_slice(&bytes) {
            Ok(v) => Ok(v),
            Err(e) => crash(&format!("`rivet yaml to-json {path}` printed invalid JSON: {e}")),
        };
    }
    let out = match Command::new("rivet").args(["yaml", "to-json", path]).output() {
        Ok(o) => o,
        Err(e) => return crash(&format!("cannot run `rivet yaml to-json {path}`: {e}")),
    };
    let _ = std::io::stderr().write_all(&out.stderr);
    if !out.status.success() {
        return crash(&format!("`rivet yaml to-json {path}` refused the file"));
    }
    match serde_json::from_slice(&out.stdout) {
        Ok(v) => Ok(v),
        Err(e) => crash(&format!("`rivet yaml to-json {path}` printed invalid JSON: {e}")),
    }
}

/// Sort every mapping's keys, recursively — what PyYAML's dump/safe_dump do by default, so
/// a fixture written here has the same shape as the one the reference wrote.
fn sorted(v: &Value) -> Value {
    match v {
        Value::Object(o) => {
            let b: BTreeMap<&String, Value> = o.iter().map(|(k, v)| (k, sorted(v))).collect();
            Value::Object(b.into_iter().map(|(k, v)| (k.clone(), v)).collect())
        }
        Value::Array(a) => Value::Array(a.iter().map(sorted).collect()),
        x => x.clone(),
    }
}

fn dump(v: &Value, path: &str) -> R<()> {
    let s = serde_json::to_string_pretty(&sorted(v)).expect("serialise JSON");
    std::fs::write(path, s + "\n").map_err(|e| Crash(format!("cannot write {path}: {e}")))
}

fn obj_mut<'a>(v: &'a mut Value, what: &str) -> R<&'a mut Map<String, Value>> {
    match v {
        Value::Object(o) => Ok(o),
        _ => crash(&format!("TypeError: {what} is not a mapping")),
    }
}

fn first_sorted(v: &Value) -> R<String> {
    let mut names = iter_names(v)?;
    names.sort();
    match names.into_iter().next() {
        Some(n) => Ok(n),
        None => crash("IndexError: list index out of range"),
    }
}

// ---- the check (run_check's Python) -----------------------------------------------------

fn check(cat_p: &str, reg_p: &str) -> R<i32> {
    // THREE ASSERTIONS, all mechanical:
    //   1. every device name a registry uses resolves to a catalogue entry. A name disagreement
    //      is what makes a bench lock VACUOUS: gale chose `stlink-v1-f100` where the registry
    //      said `stlink-v1`, two lock files with neither excluding the other (AFD-082).
    //   2. every `measured-by` artifact ID exists. A provenance claim pointing at nothing reads
    //      as evidence and is not.
    //   3. every registry ALIAS resolves too, and no alias is ambiguous. Aliases let a device be
    //      RENAMED without old and new names taking different flocks (jess#266), so an alias is
    //      a name that can take a lock and an unchecked one reopens assertion 1's hole.
    //
    // 1b: a device name may resolve to a BOARD, an ADAPTER (`standalone:`) or a SYNTHETIC entry,
    // NEVER to a PART. The rule ("EVERY DEVICE NAME IS A BOARD, NEVER A PROBE MODEL", agreed with
    // gale on jess#266 after an unpinned openocd reached the wrong board twice, gale#397) was
    // prose while this check unioned `parts` into the acceptable set: three live violations,
    // measured 2026-10-02 (AFD-136). A probe-model name is ONE LOCK FOR EVERY BOARD CARRYING THAT
    // MODEL. `parts` stays loadable so `boards[].parts` can be cross-checked; it is not a
    // namespace a device may be named from.
    let cat = load(cat_p)?;
    // An EMPTY catalogue file is `null` from rivet. It used to crash on `.get`; it is refused
    // by name instead, since "the catalogue is empty" is the verdict, not an interpreter error.
    if cat.is_null() {
        println!("  CATALOGUE IS EMPTY: {cat_p} holds no document — nothing to check names against");
        return Ok(1);
    }
    let lockable: BTreeSet<String> = set_of(&or_dict(&get(&cat, "boards")?))?
        .into_iter()
        .chain(set_of(&or_dict(&get(&cat, "standalone")?))?)
        .chain(set_of(&or_dict(&get(&cat, "synthetic")?))?)
        .collect();
    let part_only: BTreeSet<String> =
        set_of(&or_dict(&get(&cat, "parts")?))?.difference(&lockable).cloned().collect();
    let names: BTreeSet<String> = lockable.union(&part_only).cloned().collect();
    let reg = or_dict(&load(reg_p)?);
    let devices = or_dict(&get(&reg, "devices")?);
    let used: BTreeSet<String> = match &devices {
        Value::Object(o) => o.keys().cloned().collect(),
        _ => return crash("AttributeError: .keys() on a non-mapping"),
    };
    // ZERO DEVICES CHECKED IS NOT A PASS. An empty registry (no content, or no `devices:`) used
    // to print "names: 0/0 registry devices resolve" and then CATALOG OK, a green verdict over an
    // empty denominator. Refused, so a registry that failed to load or was truncated cannot pass.
    if used.is_empty() {
        println!("  REGISTRY HAS NO DEVICES: {reg_p} — 0 names to check; refusing to report a pass");
        return Ok(1);
    }
    let mut fail = 0;

    let missing: Vec<&String> = used.difference(&names).collect();
    if !missing.is_empty() {
        println!("  UNKNOWN TO THE CATALOGUE: {}", py_list(missing));
        println!("    A registry naming a device the catalogue does not contain is the vacuous-lock");
        println!("    failure returning: two agents can then name the same hardware differently.");
        fail = 1;
    } else {
        println!("  names: {}/{} registry devices resolve in the catalogue", used.len(), used.len());
    }

    // 1c: a `standalone:` entry MUST carry a serial. That section is for a device that IS the
    // claimable thing; the only thing separating it from a probe MODEL is that there is exactly
    // one of it, identified by serial. Without one, `stlink-v2-1` would be legal there.
    let mut noserial = vec![];
    for (k, v) in items(&or_dict(&get(&cat, "standalone")?))? {
        if !truthy(&get(&or_dict(&v), "serial")?) {
            noserial.push(k);
        }
    }
    noserial.sort();
    if !noserial.is_empty() {
        println!("  STANDALONE ENTRY WITH NO SERIAL: {}", py_list(&noserial));
        println!("    `standalone:` is for one physical object, distinguished from a probe MODEL by its");
        println!("    serial. Without one the name cannot be shown to mean a single device, which is");
        println!("    exactly what assertion 1b refuses in the `parts:` section.");
        fail = 1;
    }

    let named_parts: Vec<&String> = used.intersection(&part_only).collect();
    if !named_parts.is_empty() {
        println!("  A DEVICE IS NAMED AFTER A PART, NOT A BOARD: {}", py_list(named_parts));
        println!("    The catalogue lists these under `parts:` — they are component MODELS. A probe");
        println!("    model is one lock for every board carrying it, so two boards on one host share");
        println!("    a single lock and the interlock does not exclude (gale#397, jess#266).");
        println!("    Rename the device after its BOARD and keep the old name as an `aliases:` entry,");
        println!("    so a claim already held under the old name still excludes.");
        fail = 1;
    }

    // `with-device` refuses an ambiguous registry at run time; this refuses it in CI, before
    // anyone is holding anything. An alias colliding with another device's name, or claimed by
    // two devices, is refused rather than resolved: the lock would exclude the wrong agent.
    // Assertion 3 — aliases. `owner` keeps insertion order like the reference's dict.
    let mut owner: Vec<(String, String)> = vec![];
    let mut alias_fail = 0;
    for (dev, e) in items(&devices)? {
        let a = or_list(&get(&or_dict(&e), "aliases")?);
        let list = match &a {
            Value::String(s) => vec![s.clone()],
            other => iter_names(other)?,
        };
        for a in list {
            let prev = owner.iter().find(|(k, _)| *k == a).map(|(_, d)| d.clone());
            if used.contains(&a) && a != dev {
                println!("  AMBIGUOUS ALIAS: '{a}' is an alias of '{dev}' AND a device in its own right");
                alias_fail = 1;
            } else if let Some(p) = prev.as_ref().filter(|p| **p != dev) {
                println!("  AMBIGUOUS ALIAS: '{a}' is claimed by both '{p}' and '{dev}'");
                alias_fail = 1;
            }
            match owner.iter_mut().find(|(k, _)| *k == a) {
                Some(slot) => slot.1 = dev.clone(),
                None => owner.push((a, dev.clone())),
            }
        }
    }
    // An alias is held to 1b's SPIRIT, not its letter. What 1b protects against is ONE NAME
    // REACHING TWO BOARDS (gale#397: `stlink-v2-1` could mean either of two boards on one host).
    // A flat ban on part-named aliases was tried and was wrong: it refused the compatibility
    // aliases this gate's own prescribed rename creates, and five committed scripts pass
    // `stlink-v1` as a device name (hardware/silicon/f100*/run-on-silicon.sh,
    // negative-control.sh). The test is AMBIGUITY against the catalogue, resolved per registry,
    // because ambiguity is a property of one host's hardware.
    let mut cat_parts: HashMap<String, BTreeSet<String>> = HashMap::new();
    for sect in ["boards", "standalone"] {
        for (k, v) in items(&or_dict(&get(&cat, sect)?))? {
            let mut p = set_of(&or_list(&get(&or_dict(&v), "parts")?))?;
            if sect == "standalone" {
                p.insert(k.clone());
            }
            cat_parts.insert(k, p);
        }
    }
    let owned: BTreeSet<String> = owner.iter().map(|(k, _)| k.clone()).collect();
    let owner_of = |a: &str| owner.iter().find(|(k, _)| k == a).map(|(_, d)| d.clone()).unwrap();
    for a in owned.intersection(&part_only) {
        let carriers: Vec<&String> =
            used.iter().filter(|d| cat_parts.get(*d).map_or(false, |s| s.contains(a))).collect();
        if carriers.len() > 1 {
            println!(
                "  AMBIGUOUS ALIAS (A PART CARRIED BY SEVERAL REGISTERED DEVICES): '{a}' -> {}",
                py_list(carriers)
            );
            println!("    This is exactly gale#397: one name an agent can type that reaches more than");
            println!("    one board on this host. Name the board instead.");
            alias_fail = 1;
        } else if carriers.is_empty() {
            println!("  ALIAS NAMES A PART NO REGISTERED DEVICE CARRIES: '{a}'");
            println!("    It would take a lock standing for nothing on this host.");
            alias_fail = 1;
        } else if *carriers[0] != owner_of(a) {
            println!("  MISLEADING ALIAS: '{a}' is an alias of '{}', but the only registered", owner_of(a));
            println!("    device carrying that part is '{}'. The name would take one", carriers[0]);
            println!("    board's lock while naming another's hardware.");
            alias_fail = 1;
        }
    }
    let unknown_alias: Vec<&String> = owned.difference(&names).collect();
    if !unknown_alias.is_empty() {
        println!("  ALIAS UNKNOWN TO THE CATALOGUE: {}", py_list(unknown_alias));
        println!("    An alias is a name that can take a lock. One the catalogue does not contain is");
        println!("    the same vacuous-lock failure as assertion 1, under a different key.");
        alias_fail = 1;
    }
    if alias_fail != 0 {
        fail = 1;
    } else if !owner.is_empty() {
        println!("  aliases: {} alias(es) resolve and are unambiguous", owner.len());
    } else {
        println!("  aliases: none declared");
    }

    let mut cited: BTreeSet<String> = BTreeSet::new();
    for sect in ["parts", "boards"] {
        let s = or_dict(&get(&cat, sect)?);
        let vals: Vec<Value> = match &s {
            Value::Object(o) => o.values().cloned().collect(),
            _ => return crash("AttributeError: .values() on a non-mapping"),
        };
        for e in vals {
            cited.extend(iter_names(&or_list(&get(&e, "measured-by")?))?);
        }
    }
    // FAIL CLOSED with a NAMED reason: "cannot verify" is a verdict this check may reach,
    // crashing is not. (The Python's first version died with a traceback on a missing rivet.)
    if !cited.is_empty() {
        match provenance_ids() {
            Ok(have) => {
                let dangling: Vec<&String> = cited.difference(&have).collect();
                if !dangling.is_empty() {
                    println!(
                        "  DANGLING PROVENANCE: {} — cited as measuring a fact, does not exist",
                        py_list(dangling)
                    );
                    fail = 1;
                } else {
                    println!("  provenance: {} cited artifacts all exist", cited.len());
                }
            }
            Err(Prov::NotFound) => {
                println!("  provenance: CANNOT VERIFY — `rivet` is not on PATH.");
                println!("    This check needs it to confirm every measured-by citation names a real");
                println!("    artifact. Refusing to report a pass on a claim it could not check.");
                fail = 1;
            }
            Err(Prov::Other(name)) => {
                println!("  provenance: CANNOT VERIFY ({name}) — refusing to report a pass");
                fail = 1;
            }
        }
    }
    Ok(fail)
}

enum Prov {
    NotFound,
    /// The Python exception class the reference would have caught.
    Other(&'static str),
}

/// The artifact IDs `rivet list --format json` reports. Like the reference, rivet's exit
/// code is not consulted: only its stdout, which must parse.
fn provenance_ids() -> Result<BTreeSet<String>, Prov> {
    // Component mode: component-run.sh ran `rivet list --format json` and names its stdout here,
    // or "!NotFound" / "!PermissionError" / "!OSError" when rivet could not be started.
    let stdout = match std::env::var("CHECK_CATALOG_PROVENANCE") {
        Ok(f) => match f.as_str() {
            "!NotFound" => return Err(Prov::NotFound),
            "!PermissionError" => return Err(Prov::Other("PermissionError")),
            "!OSError" => return Err(Prov::Other("OSError")),
            _ => std::fs::read(&f).map_err(|_| Prov::Other("OSError"))?,
        },
        Err(_) => match Command::new("rivet").args(["list", "--format", "json"]).output() {
            Ok(o) => o.stdout,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(Prov::NotFound),
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => return Err(Prov::Other("PermissionError")),
            Err(_) => return Err(Prov::Other("OSError")),
        },
    };
    let text = String::from_utf8(stdout).map_err(|_| Prov::Other("UnicodeDecodeError"))?;
    let d: Value = serde_json::from_str(&text).map_err(|_| Prov::Other("JSONDecodeError"))?;
    let arts = match &d {
        Value::Array(_) => d.clone(),
        Value::Object(o) => o.get("artifacts").cloned().unwrap_or_else(|| d.clone()),
        _ => return Err(Prov::Other("AttributeError")),
    };
    let elems: Vec<Value> = match &arts {
        Value::Array(a) => a.clone(),
        Value::Object(o) => o.keys().map(|k| Value::String(k.clone())).collect(),
        Value::String(s) => s.chars().map(|c| Value::String(c.to_string())).collect(),
        _ => return Err(Prov::Other("TypeError")),
    };
    let mut have = BTreeSet::new();
    for a in elems {
        match a {
            Value::Object(o) => match o.get("id") {
                None => return Err(Prov::Other("KeyError")),
                Some(Value::Array(_)) | Some(Value::Object(_)) => return Err(Prov::Other("TypeError")),
                Some(Value::String(s)) => {
                    have.insert(s.clone());
                }
                // A number/bool/null id is hashable and can never equal a cited string.
                Some(_) => {}
            },
            _ => return Err(Prov::Other("TypeError")),
        }
    }
    Ok(have)
}

// ---- self-test fixture writers (the PYNC* blocks) ---------------------------------------

fn lockable_part_only(cat: &Value) -> R<Vec<String>> {
    let mut lockable = set_of(&or_dict(&get(cat, "boards")?))?;
    lockable.extend(set_of(&or_dict(&get(cat, "standalone")?))?);
    lockable.extend(set_of(&or_dict(&get(cat, "synthetic")?))?);
    let parts = set_of(&or_dict(&get(cat, "parts")?))?;
    Ok(parts.difference(&lockable).cloned().collect())
}

fn reg_devices(reg: &Value) -> R<Value> {
    match reg {
        Value::Object(o) => match o.get("devices") {
            Some(d) => Ok(d.clone()),
            None => crash("KeyError: 'devices'"),
        },
        _ => crash("TypeError: the registry is not a mapping"),
    }
}

fn first_device(reg_p: &str) -> R<i32> {
    let reg = load(reg_p)?;
    println!("{}", first_sorted(&reg_devices(&reg)?)?);
    Ok(0)
}

fn set_aliases(reg: &mut Value, dev: &str, aliases: Value) -> R<()> {
    let devs = obj_mut(obj_mut(reg, "the registry")?.get_mut("devices").unwrap(), "devices")?;
    let e = devs.get_mut(dev).unwrap();
    obj_mut(e, "a device entry")?.insert("aliases".into(), aliases);
    Ok(())
}

/// NC3/NC4. NC4 needs a SECOND registered device for the alias to collide with; when the
/// registry has only one, a catalogue board is registered as it (AFD-154).
fn fixture_alias(cat_p: &str, reg_p: &str, out_unknown: &str, out_collide: &str) -> R<i32> {
    let cat = load(cat_p)?;
    let reg = load(reg_p)?;
    let d = reg_devices(&reg)?;
    if !d.is_object() {
        return crash("TypeError: devices is not a mapping");
    }
    let first = first_sorted(&d)?;
    let mut a = reg.clone();
    set_aliases(&mut a, &first, serde_json::json!(["no-such-board"]))?;
    dump(&a, out_unknown)?;
    let mut b = reg.clone();
    let mut keys = iter_names(&d)?;
    keys.sort();
    let other = match keys.into_iter().find(|k| *k != first) {
        Some(o) => o,
        None => {
            let mut spare: Vec<String> = iter_names(&or_dict(&get(&cat, "boards")?))?
                .into_iter()
                .filter(|k| !d.as_object().unwrap().contains_key(k))
                .collect();
            spare.sort();
            let Some(o) = spare.into_iter().next() else {
                return crash("IndexError: list index out of range");
            };
            let devs = obj_mut(obj_mut(&mut b, "the registry")?.get_mut("devices").unwrap(), "devices")?;
            devs.insert(o.clone(), serde_json::json!({"what": "NC4 second device"}));
            o
        }
    };
    set_aliases(&mut b, &first, Value::Array(vec![Value::String(other)]))?;
    dump(&b, out_collide)?;
    Ok(0)
}

fn fixture_dev_is_part(cat_p: &str, reg_p: &str, out: &str) -> R<i32> {
    let cat = load(cat_p)?;
    let reg = load(reg_p)?;
    let part_only = lockable_part_only(&cat)?;
    let part = match part_only.first() {
        Some(p) => p.clone(),
        None => return crash("AssertionError: the catalogue has no parts-only entry, so NC5/NC6 would be vacuous"),
    };
    let d = first_sorted(&reg_devices(&reg)?)?;
    let mut a = reg.clone();
    let devs = obj_mut(obj_mut(&mut a, "the registry")?.get_mut("devices").unwrap(), "devices")?;
    let v = devs.shift_remove(&d).unwrap();
    devs.insert(part.clone(), v);
    dump(&a, out)?;
    println!("  (NC5/NC6 use the part name '{part}')");
    Ok(0)
}

fn fixture_alias_ambig(cat_p: &str, reg_p: &str, o_ambig: &str, o_one: &str, o_wrong: &str) -> R<i32> {
    let cat = load(cat_p)?;
    let reg = load(reg_p)?;
    let boards = or_dict(&get(&cat, "boards")?);
    let board_items = items(&boards)?;
    let mut by_part: Vec<(String, Vec<String>)> = vec![];
    for (b, v) in &board_items {
        for pt in iter_names(&or_list(&get(&or_dict(v), "parts")?))? {
            match by_part.iter_mut().find(|(k, _)| *k == pt) {
                Some(slot) => slot.1.push(b.clone()),
                None => by_part.push((pt, vec![b.clone()])),
            }
        }
    }
    let mut shared: Vec<(String, Vec<String>)> = by_part.iter().filter(|(_, bs)| bs.len() > 1).cloned().collect();
    shared.sort();
    let Some((part, bs)) = shared.first().cloned() else {
        return crash("AssertionError: no part is carried by two boards — NC6 would be vacuous");
    };
    let mut bs = bs;
    bs.sort();
    let (b1, b2) = (bs[0].clone(), bs[1].clone());
    let mut solo: Vec<String> = by_part.iter().filter(|(_, bs)| bs.len() == 1).map(|(p, _)| p.clone()).collect();
    solo.sort();
    if solo.is_empty() {
        return crash("AssertionError: no part carried by exactly one board — NC6b would be vacuous");
    }
    let base = || -> R<Value> {
        let mut r = reg.clone();
        obj_mut(&mut r, "the registry")?.insert("devices".into(), Value::Object(Map::new()));
        Ok(r)
    };
    let put = |r: &mut Value, k: &str, v: Value| {
        r.get_mut("devices").unwrap().as_object_mut().unwrap().insert(k.to_string(), v);
    };
    let mut a = base()?;
    put(&mut a, &b1, serde_json::json!({"what": "x", "aliases": [part]}));
    put(&mut a, &b2, serde_json::json!({"what": "y"}));
    dump(&a, o_ambig)?;
    let mut b = base()?;
    put(&mut b, &b1, serde_json::json!({"what": "x", "aliases": [part]}));
    dump(&b, o_one)?;
    let solo_part = solo[0].clone();
    let solo_board = by_part.iter().find(|(p, _)| *p == solo_part).unwrap().1[0].clone();
    let Some(other) = board_items.iter().map(|(k, _)| k.clone()).find(|x| *x != solo_board) else {
        return crash("StopIteration: no board other than the solo part's carrier");
    };
    let mut c = base()?;
    put(&mut c, &other, serde_json::json!({"what": "x", "aliases": [solo_part]}));
    put(&mut c, &solo_board, serde_json::json!({"what": "y"}));
    dump(&c, o_wrong)?;
    println!("  (NC6 uses shared part '{part}' on {b1}/{b2}; NC6c uses '{solo_part}')");
    Ok(0)
}

fn fixture_noserial(cat_p: &str, out: &str) -> R<i32> {
    let mut c = load(cat_p)?;
    let st = or_dict(&get(&c, "standalone")?);
    if !truthy(&st) {
        return crash("AssertionError: no standalone: section — NC8 would be vacuous");
    }
    if !st.is_object() {
        return crash("TypeError: standalone is not a mapping");
    }
    let k = first_sorted(&st)?;
    let entry = st.get(&k).unwrap();
    if !truthy(&get(entry, "serial")?) {
        return crash(&format!("AssertionError: standalone/{k} has no serial to remove — NC8 would be vacuous"));
    }
    let e = c.get_mut("standalone").unwrap().get_mut(&k).unwrap();
    obj_mut(e, "a standalone entry")?.shift_remove("serial");
    dump(&c, out)?;
    println!("  (NC8 strips the serial from standalone/{k})");
    Ok(0)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let a: Vec<&str> = args.iter().map(String::as_str).collect();
    let r = match a.as_slice() {
        ["--version"] => {
            println!("check-catalog {}", env!("CARGO_PKG_VERSION"));
            Ok(0)
        }
        ["check", c, r] => check(c, r),
        ["first-device", r] => first_device(r),
        ["fixture-alias", c, r, u, x] => fixture_alias(c, r, u, x),
        ["fixture-dev-is-part", c, r, o] => fixture_dev_is_part(c, r, o),
        ["fixture-alias-ambig", c, r, x, y, z] => fixture_alias_ambig(c, r, x, y, z),
        ["fixture-noserial", c, o] => fixture_noserial(c, o),
        _ => {
            eprintln!("usage: check-catalog check <catalog> <registry> | first-device <registry> | fixture-* ...");
            eprintln!("  (normally run through tools/bench/check-catalog.sh, which keeps the user-facing CLI)");
            exit(2)
        }
    };
    let _ = std::io::stdout().flush();
    match r {
        Ok(code) => exit(code),
        Err(Crash(msg)) => {
            eprintln!("check-catalog: {msg}");
            exit(1)
        }
    }
}
