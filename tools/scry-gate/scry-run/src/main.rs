//! scry sound-analysis gate for jess (REQ-PIX-018 leg b).
//!
//! Runs scry's sound abstract interpretation (`scry-sai-core`) on the
//! meld-fused falcon Core module and emits a compact JSON verdict. The gate
//! asserts scry COMPLETES (soundness liveness on the current falcon) and that
//! the unsound-fallback counts do not regress against a committed baseline —
//! the sound-analysis analogue of witness's "no branch-coverage regression".
//!
//! Mirrors synth-cli's `scry_analyze_core::{AnalysisConfig, analyze}` usage.
use scry_analyze_core::{
    analyze, AnalysisConfig, DiagnosticSeverity, SoundnessTag, StackBound,
};
use std::process::ExitCode;

fn stack_bound(b: &StackBound) -> String {
    match b {
        StackBound::Bytes(n) => format!("bytes:{n}"),
        StackBound::Unbounded => "unbounded".into(),
        StackBound::Unknown => "unknown".into(),
    }
}

fn main() -> ExitCode {
    let path = match std::env::args().nth(1) {
        Some(p) => p,
        None => {
            eprintln!("usage: scry-run <fused-core.wasm>");
            return ExitCode::FAILURE;
        }
    };
    let bytes = std::fs::read(&path).expect("read fused core wasm");
    let n = bytes.len();
    let cfg = AnalysisConfig::default();
    let r = match analyze(bytes, cfg) {
        Ok(r) => r,
        Err(e) => {
            // scry could NOT soundly analyze the fused core -> hard gate failure.
            eprintln!("scry ERROR (analysis did not complete): {e:?}");
            return ExitCode::FAILURE;
        }
    };

    let diag_unsound = r
        .diagnostics
        .iter()
        .filter(|d| d.severity == DiagnosticSeverity::UnsoundnessFallback)
        .count();
    let diag_warning = r
        .diagnostics
        .iter()
        .filter(|d| d.severity == DiagnosticSeverity::Warning)
        .count();
    let diag_info = r
        .diagnostics
        .iter()
        .filter(|d| d.severity == DiagnosticSeverity::Info)
        .count();
    let edges_unsound = r
        .call_graph
        .iter()
        .filter(|e| e.soundness == SoundnessTag::UnsoundFallback)
        .count();
    let edges_indirect = r.call_graph.iter().filter(|e| e.indirect).count();

    // Compact, diffable JSON verdict (stable key order, no float noise).
    println!("{{");
    println!("  \"scry_sai_core\": \"1.18.0\",");
    println!("  \"invariants_schema\": \"{}\",", r.invariants.schema);
    println!("  \"module_sha256\": \"{}\",", r.invariants.module_sha256);
    println!("  \"module_bytes\": {n},");
    println!("  \"program_points\": {},", r.invariants.points.len());
    println!("  \"functions\": {},", r.function_summaries.len());
    println!("  \"reachable_from_exports\": {},", r.reachable_from_exports.len());
    println!("  \"call_edges\": {},", r.call_graph.len());
    println!("  \"call_edges_indirect\": {edges_indirect},");
    println!("  \"call_edges_unsound_fallback\": {edges_unsound},");
    println!("  \"taint_findings\": {},", r.taint_findings.len());
    println!("  \"diagnostics_total\": {},", r.diagnostics.len());
    println!("  \"diag_info\": {diag_info},");
    println!("  \"diag_warning\": {diag_warning},");
    println!("  \"diag_unsound_fallback\": {diag_unsound},");
    println!("  \"stack_sp_global\": {},", match r.stack_usage.sp_global { Some(g)=>g as i64, None=>-1 });
    println!("  \"stack_max_bytes\": \"{}\"", stack_bound(&r.stack_usage.max_stack_bytes));
    println!("}}");

    eprintln!(
        "scry OK: {} pts, {} funcs, {} call-edges ({} unsound-fallback), {} diagnostics ({} unsound-fallback)",
        r.invariants.points.len(), r.function_summaries.len(), r.call_graph.len(),
        edges_unsound, r.diagnostics.len(), diag_unsound
    );
    ExitCode::SUCCESS
}
