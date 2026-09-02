//! The falcon cascade driven on a schedule — the DD-025 structural rung.
//!
//! AFD-047 concluded an application could not make its own wake fire. That was wrong
//! (AFD-049): it rested on a stale artifact, and with a ticking `gust:hal/mmio.read32`
//! gale's timer path works end to end. This component is what that unblocks.
//!
//! WHAT THIS IS NOT: a real-time schedule. The rate here is whatever the embedder's
//! counter does, and under wasmtime that is a mock. This proves the LOOP STRUCTURE —
//! arm, wait, compute, repeat — not any timing property.
#![no_std]

mod bindings {
    wit_bindgen::generate!({ path: "wit", world: "loop", generate_all });
}

use bindings::gust::os::{spawn, time, timer};
use bindings::pulseengine::falcon_cascade::{mixer, rate, types};

const INVALID: u32 = 0xFFFF_FFFF;
/// Bounded so a runtime that never reports `elapsed` cannot hang the image. A flight
/// loop that spins forever waiting on a dead clock is worse than one that reports it.
const MAX_POLLS_PER_PERIOD: u32 = 100_000;

struct App;

/// The vector from tools/cascade-differential — shared so a periodic run starts from
/// the same state the single-shot differential pins.
fn initial_state() -> types::VehicleState {
    types::VehicleState {
        qw: 1.0, qx: 0.0, qy: 0.0, qz: 0.0,
        pos_n: 0.0, pos_e: 0.0, pos_d: -2.5,
        vel_n: 0.1, vel_e: -0.2, vel_d: 0.05,
        wx: 0.30, wy: -0.15, wz: 0.07,
        innovation: 0.0,
    }
}

impl bindings::Guest for App {
    /// Packed result — DISJOINT FIELDS, because an earlier probe in this repo packed
    /// two fields into overlapping bits and its decoder printed a coincidental PASS.
    ///
    ///   bits  0..9   iterations actually completed (0..1023)
    ///   bit  10      every period's wake FIRED (no period exhausted its poll budget)
    ///   bit  11      the fold VARIED across iterations
    ///   bit  12      the clock advanced from first read to last
    ///   bits 16..31  low 16 bits of the final fold
    ///
    /// NOTE on `ticks_per_period == 0`: `sleep(h, 0)` means "wake immediately", so a
    /// zero-tick period completes every iteration WITHOUT the clock advancing — a busy
    /// loop wearing a schedule's clothes. The oracle catches it (the frozen-clock arm
    /// stops reporting 0 iterations), and it is left as the runtime's own semantics
    /// rather than special-cased here, because silently rewriting a caller's 0 into a 1
    /// would hide the mistake instead of surfacing it.
    fn run_loop(iterations: u32, ticks_per_period: u32) -> u32 {
        let t_start = time::now();
        let h = spawn::start(0);
        if h == INVALID {
            return 0; // no handle: zero iterations, no flags — indistinguishable from
                      // "did nothing", which is the honest report for this case.
        }

        let mut done: u32 = 0;
        let mut all_fired = true;
        let mut first_fold: u32 = 0;
        let mut last_fold: u32 = 0;
        let mut varied = false;

        let n = if iterations > 1023 { 1023 } else { iterations };
        let mut i = 0u32;
        while i < n {
            // --- arm the period ---
            if timer::sleep(h, ticks_per_period) != 0 {
                all_fired = false;
                break;
            }
            // --- wait for it, with a budget ---
            let mut polls = 0u32;
            let mut fired = false;
            while polls < MAX_POLLS_PER_PERIOD {
                let s = timer::slept(h);
                if s == 1 { fired = true; break; }
                if s == INVALID { break; }
                polls += 1;
            }
            if !fired {
                all_fired = false;
                break;
            }

            // --- the actual work: one cascade step ---
            let sp = types::RateSetpoint { rx: 1.0, ry: 0.0, rz: 0.0, thrust: 0.5 };
            let torque = rate::tick(initial_state(), sp);
            let pwm = mixer::mix(torque);
            let fold = (pwm.m1 + pwm.m2 + pwm.m3 + pwm.m4).to_bits() & 0x7fff_ffff;

            if i == 0 { first_fold = fold; } else if fold != first_fold { varied = true; }
            last_fold = fold;

            done += 1;
            i += 1;
        }

        // The cascade carries integrator state, so a fold that VARIES across iterations
        // is positive evidence the loop genuinely re-executed rather than running once
        // and reporting a count. A constant fold across >1 iterations would mean the
        // body did not actually re-run — the failure this bit exists to catch.
        let clock_moved = time::now() != t_start;

        (done & 0x3FF)
            | ((all_fired as u32) << 10)
            | ((varied as u32) << 11)
            | ((clock_moved as u32) << 12)
            | ((last_fold & 0xFFFF) << 16)
    }
}

bindings::export!(App with_types_in bindings);
jess_bump_alloc::install!();
