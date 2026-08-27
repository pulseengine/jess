//! Bump allocator + panic handler shared by every jess wasm component.
//!
//! Factored out of `flight-app` once `gust-hal-stub` needed the identical pair:
//! two copies of an allocator is two places for the partition-sizing constant to
//! drift apart, and that constant is a safety property on a statically-sized
//! RT1176 partition, not a style preference.
#![no_std]

/// Bump allocator over `__heap_base`.
///
/// Deliberately never calls `memory.grow` and never frees: publish-gate C2 REFUSES a
/// component that grows memory, because the RT1176 partition is statically sized and a
/// grow at flight time is an unbounded fault. Exhaustion traps rather than falling back
/// — a silent wrap would corrupt the cascade's state instead of failing loudly.
pub mod alloc_impl {
    use core::alloc::{GlobalAlloc, Layout};
    use core::sync::atomic::{AtomicUsize, Ordering};

    extern "C" {
        static __heap_base: u8;
    }
    const HEAP_LEN: usize = 64 * 1024;
    static NEXT: AtomicUsize = AtomicUsize::new(0);

    pub struct Bump;
    unsafe impl GlobalAlloc for Bump {
        unsafe fn alloc(&self, l: Layout) -> *mut u8 {
            let base = &__heap_base as *const u8 as usize;
            loop {
                let cur = NEXT.load(Ordering::Relaxed);
                let start = (base + cur + l.align() - 1) & !(l.align() - 1);
                let end = start - base + l.size();
                if end > HEAP_LEN {
                    return core::ptr::null_mut(); // triggers alloc_error -> trap
                }
                if NEXT.compare_exchange_weak(cur, end, Ordering::Relaxed, Ordering::Relaxed).is_ok()
                {
                    return start as *mut u8;
                }
            }
        }
        unsafe fn dealloc(&self, _: *mut u8, _: Layout) {}
    }
}

/// Install the allocator and panic handler. Every jess component calls this once.
#[macro_export]
macro_rules! install {
    () => {
        #[global_allocator]
        static __JESS_ALLOC: $crate::alloc_impl::Bump = $crate::alloc_impl::Bump;

        #[panic_handler]
        fn __jess_panic(_: &core::panic::PanicInfo) -> ! {
            // panic = abort at the wasm level; unreachable traps deterministically.
            core::arch::wasm32::unreachable()
        }
    };
}

