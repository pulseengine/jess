//! The jess flight application — the DD-026 seam made real.
//!
//! This is the piece AFD-043 identified as missing: falcon imports no `gust:os`,
//! gale-nano exports it, and nothing joined the two. This crate is that join. It
//! is deliberately the THINNEST thing that proves the seam composes — one cascade
//! step, driven by gale's clock — because the periodicity question (timer-ISR vs
//! ARINC-653 partition window, DD-025) is not yet settled by evidence.
#![no_std]

mod bindings {
    wit_bindgen::generate!({ path: "wit", world: "app", generate_all });
}

use bindings::gust::os::time;
use bindings::pulseengine::falcon_cascade::{mixer, rate, types};

struct App;

impl bindings::Guest for App {
    /// One cascade step: rate -> mixer, timed on gale's clock.
    ///
    /// Returns the elapsed-deadline verdict as u32 so the caller observes BOTH
    /// legs of the seam (falcon compute AND gust:os time) in a single value. A
    /// constant return would not distinguish "the seam ran" from "the stub ran".
    fn run() -> u32 {
        let t0 = time::now();
        let deadline = time::deadline(t0, 1);

        // EXACTLY the vector in tools/cascade-differential/sil_reference.py. Sharing it
        // is the point: the composed component's output is then directly comparable to
        // the established SIL reference, so "it ran" can be upgraded to "it ran RIGHT".
        let state = types::VehicleState {
            qw: 1.0, qx: 0.0, qy: 0.0, qz: 0.0,
            pos_n: 0.0, pos_e: 0.0, pos_d: -2.5,
            vel_n: 0.1, vel_e: -0.2, vel_d: 0.05,
            wx: 0.30, wy: -0.15, wz: 0.07,
            innovation: 0.0,
        };
        let sp = types::RateSetpoint { rx: 1.0, ry: 0.0, rz: 0.0, thrust: 0.5 };

        let torque = rate::tick(state, sp);
        let pwm = mixer::mix(torque);

        // Fold the motor outputs to a single observable word. Bit 31 carries the
        // clock leg so a stalled `time` import is distinguishable from a bad mix.
        // BIT-EXACT, not scaled-and-truncated. The original folded `sum * 1000.0` to an
        // integer, which accepts any reference sum in [1.348, 1.349) — a 0.07% window.
        // Clean-room verification falsified the reference's thrust setpoint to 0.75 and
        // the oracle still reported PASS. Comparing the raw f32 bits closes that window
        // to a single value; the sign bit is dropped (the sum is positive) so bit 31
        // stays available for the clock leg.
        let acc_bits = (pwm.m1 + pwm.m2 + pwm.m3 + pwm.m4).to_bits() & 0x7fff_ffff;

        // Bit 31 must DISCRIMINATE, not merely be present. `elapsed(...) == false`
        // was the first choice and it is vacuous: an inert clock returns false too.
        // `deadline(t0, 1) != t0` cannot be produced by a stub that returns zeros —
        // it is true only if gale actually did the tick arithmetic on our argument.
        let clock_live = (deadline != t0) as u32;
        acc_bits | (clock_live << 31)
    }
}

bindings::export!(App with_types_in bindings);

jess_bump_alloc::install!();
