//! Does the SHIPPED gale-nano actually implement gale's documented timer semantics?
//!
//! gale (#223) documents: `slept` returns 0 pending / 1 elapsed / 0xFFFF_FFFF invalid,
//! and `sleep` returns 0xFFFF_FFFF for a handle it does not own. Those are CLAIMS until
//! run against the shipped artifact — the loop's standing rule is to verify resolution
//! against the real build, never the claim.
//!
//! This probe returns a BITFIELD rather than a pass/fail so a failure says WHICH leg
//! broke. A boolean would collapse four independent observations into one bit.
#![no_std]

mod bindings {
    wit_bindgen::generate!({ path: "wit", world: "probe", generate_all });
}

use bindings::gust::os::{exec, spawn, time, timer};

const INVALID: u32 = 0xFFFF_FFFF;

struct P;

impl bindings::Guest for P {
    fn run() -> u32 {
        let mut f = 0u32;

        // bit 0 — the clock does real arithmetic on our argument (not an inert stub)
        let t0 = time::now();
        if time::deadline(t0, 1) != t0 { f |= 1 << 0; }

        // bit 1 — spawn yields a handle that is NOT the invalid sentinel
        let h = spawn::start(0);
        if h != INVALID { f |= 1 << 1; }

        // bit 2 — arming a wake on THAT handle succeeds (gale: 0 = armed)
        let armed = timer::sleep(h, 1);
        if armed == 0 { f |= 1 << 2; }

        // bit 3 — polling the armed handle returns a DEFINED state, not the sentinel.
        //         NOTE: 0 (pending) is a legitimate answer, so "not INVALID" is the
        //         property under test here, not "elapsed".
        let s = timer::slept(h);
        if s != INVALID { f |= 1 << 3; }

        // bit 4 — THE NEGATIVE CONTROL, and the reason this probe is not vacuous:
        //         a handle gale cannot own MUST come back invalid. Without this, bits
        //         2-3 would also be satisfied by a runtime that returns 0 for
        //         everything, which is exactly the stub we are trying to rule out.
        if timer::sleep(INVALID, 1) == INVALID { f |= 1 << 4; }

        // FIRST: does the clock ADVANCE at all in this composition? If it does not,
        // every "the wake never fired" conclusion below is an artifact of a frozen
        // clock, not a statement about gale. jess's gust-hal stub returns a value
        // DERIVED FROM THE ADDRESS, which is constant per address — so if gale's
        // time::now() reads an MMIO counter through it, the clock cannot tick.
        let ta = time::now();
        let mut spins = 0u32;
        while spins < 1000 && time::now() == ta { spins += 1; }
        let clock_advances = (time::now() != ta) as u32;
        if clock_advances == 1 { f |= 1 << 5; }

        // bits 16..31 — THE DD-025 QUESTION, made empirical.
        //
        // gale's example polls `slept` in a bounded loop. gale also states plainly that
        // the example never calls `exec.poll-round`, and that WHO DRIVES THE EXECUTOR —
        // timer ISR vs ARINC-653 partition window — is still open (gale#223).
        //
        // So: can an application drive its own wake purely by polling? Count the polls
        // until `slept` reports elapsed. If it NEVER does, an app cannot self-drive and
        // something outside it must advance the executor. That is a decidable question,
        // and the count is the evidence either way.
        const MAX_POLLS: u32 = 10_000;
        let mut synth_now: u32 = ta as u32;
        let mut i = 0u32;
        let mut elapsed_at = 0u32;
        let mut last = 0u32;
        while i < MAX_POLLS {
            // Drive the executor ourselves, supplying the current time — note that
            // poll-round takes the clock as an ARGUMENT (now-lo/now-hi), which is
            // itself a hint about who is expected to call it: whoever owns the clock.
            // poll-round takes the time as an ARGUMENT. If gale expects the DRIVER to
            // supply the clock, then feeding it a synthetic advancing time — rather
            // than the frozen now() — should let the wake fire. That distinguishes
            // "the clock needs an external source" from "the executor needs a driver".
            exec::poll_round(synth_now, 0);
            synth_now = synth_now.wrapping_add(1);
            last = timer::slept(h);
            if last == 1 { elapsed_at = i + 1; break; }
            if last == INVALID { break; }   // NOT the same as exhausting the loop
            i += 1;
        }
        // elapsed_at == 0 means "never elapsed in MAX_POLLS" — the interesting answer.
        // Expose now() itself, low 16 bits, so a frozen clock is DIAGNOSABLE rather
        // than merely observable — "it does not advance" and "it is always N" are
        // different facts and only the second names a cause.
        // Report polls-actually-made AND the last value, because elapsed_at==0 alone
        // conflates "polled 10,000 times, never elapsed" with "broke out at poll 0 on
        // an INVALID handle". Those are different facts; one is evidence, one is a bug.
        // EVERY FIELD GETS ITS OWN BITS. An earlier version dropped `f` from this
        // expression, so the decoder read the poll count as the semantics flags and
        // printed a coincidental PASS. Overlapping fields is how a probe lies.
        //   0..5   semantics flags        6..7   last slept() value
        //   8..21  polls actually made   22..31  elapsed_at (capped)
        (f & 0x3F)
            | ((last & 0x3) << 6)
            | ((core::cmp::min(i, 0x3FFF) & 0x3FFF) << 8)
            | ((core::cmp::min(elapsed_at, 0x3FF) & 0x3FF) << 22)
    }
}

bindings::export!(P with_types_in bindings);
jess_bump_alloc::install!();
