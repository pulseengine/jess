//! Drives gale-nano's `gust:os/exec.poll-round` and reports what the dispatcher actually did.
//!
//! gale#223: "Drive one round at time `now`: fire the tickless alarm, then drain every ready
//! task exactly once through `taskdisp.poll-task`." This turns that sentence into a
//! measurement. The observation lives in jess:gust-dispatch-probe, whose poll-task counts
//! its own invocations; this component only sequences the calls.
#![no_std]

mod bindings {
    wit_bindgen::generate!({ path: "wit", world: "driver", generate_all });
}

use bindings::gust::os::exec;
use bindings::jess::gust_dispatch_probe::probe;

const PRIO: u32 = 1;
const DEADLINE_LO: u32 = 1_000;
const DEADLINE_HI: u32 = 0;
const NOW_LO: u32 = 2_000;   // past the deadline, so an admitted task is READY
const NOW_HI: u32 = 0;

struct Comp;

impl bindings::Guest for Comp {
    /// admit -> poll-round -> read the counter. One instance, one round.
    fn with_admit() -> u32 {
        let _h = exec::admit(PRIO, DEADLINE_LO, DEADLINE_HI);
        exec::poll_round(NOW_LO, NOW_HI);
        probe::polls()
    }

    /// The negative control. Byte-for-byte the same as with_admit EXCEPT the admit call —
    /// same instance shape, same now, same round. If this also reports a non-zero count then
    /// the counter is measuring something other than task dispatch and the positive result
    /// means nothing (AFD-048: a control must differ in exactly one variable).
    fn without_admit() -> u32 {
        exec::poll_round(NOW_LO, NOW_HI);
        probe::polls()
    }

    /// "drain EVERY ready task exactly once" — the EVERY half.
    fn two_tasks_one_round() -> u32 {
        let _a = exec::admit(PRIO, DEADLINE_LO, DEADLINE_HI);
        let _b = exec::admit(PRIO, DEADLINE_LO, DEADLINE_HI);
        exec::poll_round(NOW_LO, NOW_HI);
        probe::polls()
    }

    /// "drain every ready task EXACTLY ONCE" — the ONCE half. poll-task returns 0
    /// (complete), so the second round must not re-poll a finished task.
    fn one_task_two_rounds() -> u32 {
        let _a = exec::admit(PRIO, DEADLINE_LO, DEADLINE_HI);
        exec::poll_round(NOW_LO, NOW_HI);
        exec::poll_round(NOW_LO, NOW_HI);
        probe::polls()
    }

    /// What gale itself reports about the task after a round. Reading the dispatcher's own
    /// state is stronger evidence than counting jess-side callbacks, because it does not
    /// depend on jess's reading of an undocumented return value.
    fn state_after_round() -> u32 {
        let h = exec::admit(PRIO, DEADLINE_LO, DEADLINE_HI);
        exec::poll_round(NOW_LO, NOW_HI);
        exec::state(h)
    }

    fn state_before_round() -> u32 {
        let h = exec::admit(PRIO, DEADLINE_LO, DEADLINE_HI);
        exec::state(h)
    }

    fn unpolled_id() -> u32 {
        exec::poll_round(NOW_LO, NOW_HI);
        probe::last_id()
    }

    fn admitted_handle() -> u32 {
        exec::admit(PRIO, DEADLINE_LO, DEADLINE_HI)
    }

    /// admit -> poll-round -> which id did poll-task actually receive?
    fn observed_id() -> u32 {
        let _h = exec::admit(PRIO, DEADLINE_LO, DEADLINE_HI);
        exec::poll_round(NOW_LO, NOW_HI);
        probe::last_id()
    }
}

bindings::export!(Comp with_types_in bindings);

jess_bump_alloc::install!();
