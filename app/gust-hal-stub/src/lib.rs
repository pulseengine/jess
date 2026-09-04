//! jess's native residual, stubbed so a composed image can RUN off-target.
#![no_std]

mod bindings {
    wit_bindgen::generate!({ path: "wit", world: "hal", generate_all });
}

use bindings::exports::gust::hal::mmio::Guest as Mmio;
use bindings::exports::gust::os::taskdisp::Guest as TaskDisp;

struct Stub;

impl Mmio for Stub {
    /// Returns a value DERIVED FROM THE ADDRESS, not a constant.
    ///
    /// A constant (0, or 0xDEADBEEF) would make a stubbed read indistinguishable
    /// from a read that never happened — the same vacuous-metric trap that voided
    /// the CRC claim in AFD-037. Folding the address in means a caller can prove
    /// the stub was actually reached with the argument it expected.
    fn read32(addr: u32) -> u32 {
        addr ^ 0x1E55_0000
    }
    fn write32(_addr: u32, _val: u32) {
        // No silicon off-target. Real MMIO is the on-target rung, not this one.
    }
}

impl TaskDisp for Stub {
    /// Reports COMPLETE. The value is load-bearing and its polarity was MEASURED, not
    /// assumed (AFD-067): with gale-nano 0.7.0, returning 0 leaves the task in
    /// `exec.state` 1 and it is re-polled by every subsequent `exec.poll-round`;
    /// returning 1 moves it to state 2 and it is not polled again.
    ///
    /// This comment previously said "0 = task complete ... cannot livelock", which was
    /// exactly backwards — 0 means "still ready, poll me again". A driver that admitted a
    /// task and looped would have spun forever. gale-nano's shipped WIT documents no
    /// semantics for this return value at all (gust:os/taskdisp is bare
    /// `poll-task: func(id: u32) -> u32`), so it was an assumption, not a contract.
    fn poll_task(_id: u32) -> u32 {
        1
    }
}

bindings::export!(Stub with_types_in bindings);

jess_bump_alloc::install!();
