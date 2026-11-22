# Run 1, 2026-11-22: stopped before any load

The first attempt (round 1, `ekf`) was `refused`. Zero load attempts were made, so 0 of the 60 counted.

- The disarmed gate (`preflight-disarmed.py`) blocked in the kernel's `set_termios` on `/dev/ttyACM0` for about 5 minutes. I killed it, and it exited through its fail-closed path.
- A separate read-only probe under a `pixhawk-6xrt` claim then received **0 bytes in 8 s** from the FMU's USB port (`timeout 8 cat`, rc 124).
- On 2026-11-17 the same port streamed 64,285 B in 6 s.
- The FMU stayed enumerated as 3643:001d throughout. Nothing was loaded, written or reset.

The cause is not established. The owner's decision is notice 20261122T155801-321c73.

The hang has a second, separate finding. The gate has no bound on the open/termios step, so "could not determine" took about 5 minutes and a manual kill instead of exiting 1.

## Correction, same day

The "0 bytes" measurement above is not evidence about the FMU. There are two reasons.
1. It read `/dev/ttyACM0` without mapping the node to a device. After the probe host rebooted at 17:33, `ttyACM0` belonged to an unrelated USB radio (04b4, iU893A) and the FMU was `ttyACM1`. What was on `ttyACM0` during run 1 can no longer be determined.
2. It used `cat`, which reads in cooked mode (AFD-128).

After the owner's power cycle, the gate run on the FMU's `/dev/serial/by-id` path read 99,649 B in 8 s and 8 heartbeats, all with SAFETY_ARMED clear, and exited 0. `campaign.sh` now passes that path as `TTY`.

`on-target-run.sh` still defaults `TTY` to `/dev/ttyACM0`, which is a defect to fix after the CI hold. The default fails closed, because a device with no heartbeat makes the gate refuse.
