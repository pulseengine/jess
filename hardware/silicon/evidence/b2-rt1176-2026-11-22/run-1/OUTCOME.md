# Run 1, 2026-11-22: stopped before any load

The first attempt (round 1, `ekf`) was `refused`. Zero load attempts were made, so 0 of the 60 counted.

- The disarmed gate (`preflight-disarmed.py`) blocked in the kernel's `set_termios` on `/dev/ttyACM0` for about 5 minutes. I killed it, and it exited through its fail-closed path.
- A separate read-only probe under a `pixhawk-6xrt` claim then received **0 bytes in 8 s** from the FMU's USB port (`timeout 8 cat`, rc 124).
- On 2026-11-17 the same port streamed 64,285 B in 6 s.
- The FMU stayed enumerated as 3643:001d throughout. Nothing was loaded, written or reset.

The cause is not established. The owner's decision is notice 20261122T155801-321c73.

The hang has a second, separate finding. The gate has no bound on the open/termios step, so "could not determine" took about 5 minutes and a manual kill instead of exiting 1.
