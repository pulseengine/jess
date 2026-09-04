//! An OBSERVABLE taskdisp, so gale-nano's dispatch loop can be measured rather than assumed.
//!
//! gale#223 states that `gust:os/exec.poll-round` fires the tickless alarm and then drains
//! every ready task exactly once through `taskdisp.poll-task`. jess's existing
//! implementation (app/gust-hal-tick) returns 0 and records nothing, which makes
//! "poll-round drained the task" and "poll-round did nothing at all" produce IDENTICAL
//! observable state. That is the vacuous-metric trap this campaign keeps hitting, so the
//! counter is the whole point of this component.
#![no_std]

mod bindings {
    wit_bindgen::generate!({ path: "wit", world: "hal", generate_all });
}

use bindings::exports::gust::hal::mmio::Guest as Mmio;
use bindings::exports::gust::os::taskdisp::Guest as TaskDisp;
use bindings::exports::jess::gust_dispatch_probe::probe::Guest as Probe;
use core::sync::atomic::{AtomicU32, Ordering};

static POLLS: AtomicU32 = AtomicU32::new(0);
/// 0xFFFF_FFFF = never called. Initialising to 0 made "poll-task saw id 0" and
/// "poll-task was never called" produce the SAME reading — and gale-nano really does
/// hand out handle 0 for the first task, so that collision was live, not theoretical.
const NEVER: u32 = 0xFFFF_FFFF;
static LAST_ID: AtomicU32 = AtomicU32::new(NEVER);
static ID_MASK: AtomicU32 = AtomicU32::new(0);

struct Comp;

impl Mmio for Comp {
    /// Monotonic and address-derived, as in gust-hal-tick: a constant would freeze any
    /// clock built on it (which voided jess's first DD-025 experiment), and a value that
    /// ignored the address could not prove the stub was reached with the address expected.
    fn read32(addr: u32) -> u32 {
        static TICKS: AtomicU32 = AtomicU32::new(0);
        let t = TICKS.fetch_add(1, Ordering::Relaxed);
        ((addr ^ 0x1E55_0000) & 0xFFFF_0000) | (t & 0x0000_FFFF)
    }
    fn write32(_addr: u32, _val: u32) {}
}

impl TaskDisp for Comp {
    /// Records the call, then reports 1. The polarity is the RESULT of this experiment,
    /// not an input to it: measured against gale-nano 0.7.0, returning 1 moves the task
    /// from exec.state 1 to 2 and it is not polled again, while returning 0 leaves it in
    /// state 1 and every subsequent round re-polls it. jess's stubs previously returned 0
    /// while their comments claimed it meant "complete" — exactly backwards.
    ///
    /// The 0-returning variant is built by tools/dispatch/run.sh as the control, so both
    /// polarities are exercised and neither is assumed.
    fn poll_task(id: u32) -> u32 {
        POLLS.fetch_add(1, Ordering::Relaxed);
        LAST_ID.store(id, Ordering::Relaxed);
        ID_MASK.fetch_or(id, Ordering::Relaxed);
        1
    }
}

impl Probe for Comp {
    fn polls() -> u32 { POLLS.load(Ordering::Relaxed) }
    fn last_id() -> u32 { LAST_ID.load(Ordering::Relaxed) }   // NEVER (0xFFFF_FFFF) if unpolled
    fn id_mask() -> u32 { ID_MASK.load(Ordering::Relaxed) }
}

bindings::export!(Comp with_types_in bindings);

jess_bump_alloc::install!();
