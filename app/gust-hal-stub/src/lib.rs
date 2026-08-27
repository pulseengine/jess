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
    /// 0 = "task complete". The stub never reports pending, so a composed image
    /// cannot livelock waiting on a dispatcher that will never advance.
    fn poll_task(_id: u32) -> u32 {
        0
    }
}

bindings::export!(Stub with_types_in bindings);

jess_bump_alloc::install!();
