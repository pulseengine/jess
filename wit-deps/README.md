# WIT extracted from the SHIPPED ARTIFACTS

Every `.wit` here was produced by `wasm-tools component wit <artifact>.wasm` against a
component pulled from ghcr — **not** copied from a supplier repo.

That is deliberate, and it is also what the repo paths force: gale's `wit-os/gust-os.wit`
404s at every path referenced (`wit-os/`, `benches/gust/wit-os/`). But the stronger reason
is that **the artifact is the contract**. A repo copy can drift from what shipped; the
binary cannot.

| file | extracted from |
|---|---|
| `gust/gust-os.wit` | `ghcr.io/pulseengine/gale-nano:0.7.0` |
| `gust/gust-hal.wit` | same |
| `falcon/pulseengine-falcon-cascade.wit` | **unioned** across the five `falcon-v1.134.1` components |

## Why the falcon package had to be reconstructed rather than copied

Each falcon component ships a **tree-shaken `types`** carrying only the records it uses:

| component | records in its `types` |
|---|---|
| rate | vehicle-state, rate-setpoint, torque-setpoint |
| iekf | **imu-sample**, vehicle-state |
| position | vehicle-state, waypoint, attitude-setpoint |
| attitude | vehicle-state, attitude-setpoint, rate-setpoint |
| mixer | torque-setpoint, motor-pwm |

**The complete type set exists in no single component.** Merging naively fails —
`error: name 'imu-sample' is not defined` — because `ekf`'s interface references a record
only `iekf`'s copy defines. The package here is the **union** of all five, which is the
only form that parses.

(`imu-sample` is the raw-IMU seam jess specified on jess#167 and relay adopted; it appears
here as shipped: `ax ay az gx gy gz`.)

## Refreshing

Re-run the extraction whenever a supplier releases; do not hand-edit these files.
