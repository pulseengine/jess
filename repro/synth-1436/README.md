# synth#1436 reproducer — the fused falcon module whose `ekf#estimate` lowers wrong

synth asked for exactly one thing: *"Naming the instruction means reading synth's output against
its input, and the input is the one thing not in the thread — `c.loom.wasm`, or the pre-loom
`c.wasm` since you measured it diverging identically. … the bench is not the gap — the module is."*

Both are here, so neither a round trip nor a rebuild stands between synth and the disassembly.

| file | sha256 | what it is |
|---|---|---|
| `c.wasm` | `d854e5bb21e0d60c89f9bd3229e1219d9ebb3cfbaafbdb211e85b7986f6a18bb` | meld's fusion of the five pinned falcon components. **Pre-loom.** |
| `c.loom.wasm` | `791ab6b5c8f661e562058ab99fc9a47fc172483f8aacb67758bb660777ece368` | the same after `loom optimize`. This is what jess lowers and runs. |

**Both diverge identically** — jess lowered and ran the pre-loom module separately and got
bit-identical wrong values, so loom is not involved and either file reproduces the defect.

## The export

`pulseengine:falcon-cascade/ekf@0.10.0#estimate` — 6 flattened f32 in (`ax ay az gx gy gz`), the
14-field `vehicle-state` out through a 56-byte return area.

## How these bytes were produced

```sh
tools/deps/fetch.sh                        # fetches + digest-verifies the pinned inputs
hardware/renode/cascade-invoke/build.sh    # meld fuse -> loom optimize -> synth compile -> link
```

Inputs, all digest-pinned in `tools/deps/artifacts.pins` (relay falcon v1.139.0 components):

```
falcon/rate.wasm      f0cb7154c543452c761443c9e50334e691a694cbd5de32f646a79bad8aa0bdd1
falcon/mixer.wasm     7df930b0e10d52033378b6fe85d24cccc924df651d925abb80390210e73105e7
falcon/attitude.wasm  d9320de9cda532906362cbc71ea291efa5a6a46889d98a76d3bdf9e57ffbad01
falcon/position.wasm  379894ec05081022a32240100d88bd2bde3a0c7dc6f35f2c14165bd30e5dde13
falcon/iekf.wasm      cf9c57385d1a4ad3e32956088b8317e2a07e372bd58a5d432772d54789cbdd65
```

Fused with **meld 0.58.3** (`--memory shared --pack-rebase --reproducible --emit-manifest`),
optimised with **loom 1.4.0**, lowered with **synth 0.77.0**:

```sh
synth compile c.loom.wasm -t cortex-m7dp --cortex-m --relocatable --all-exports \
      --embedder-data-init --embedder-global-init -o cascade.o
```

The fusion is byte-reproducible — `build.sh` fuses twice and requires the two to agree.

## Reproducing the divergence without hardware

```sh
tools/cascade-differential/ekf_ref.py repro/synth-1436/c.loom.wasm 16
```

is the wasmtime side. The IMU vector is `ax=0 ay=0 az=-9.81 gx=0.30 gy=-0.15 gz=0.07` (jess's own
choice — `--imu a,b,c,d,e,f` overrides it; relay#376 would be where an upstream vector comes from).
The ARM side needs a Cortex-M7; QEMU reproduces it with no board:

```sh
qemu-system-arm -machine mps2-an500 -cpu cortex-m7 -display none -serial none \
                -monitor stdio -kernel ekf.elf          # then: stop ; xp /31xw 0x20011400
```

## What the numbers are

Measured identically on Renode 1.16.1, QEMU 11.1.1 and the **real i.MX RT1176** (all 31 parked
words bit-identical across the three), against wasmtime over these same bytes:

| field | ARM ×3 | wasmtime |
|---|---|---|
| `pos-d` | `36a495a2` | `00000000` |
| `vel-n` | `00000000` | `b581f691` |
| `vel-e` | `00000000` | `b601f97a` |
| `vel-d` | `3c20ba20` | `00000000` |

The other ten words — including all four quaternion words and the gyro passthrough — are bit-exact.

**One refinement to the "identity rotation" reading, which holds at tick 1 but not after.** By tick
16 the north/east components are no longer zero on target:

```
tick 16, silicon:  pos-n 34e23ae4 (4.21e-07)   pos-e 35627030 (8.44e-07)
                   vel-n 38aee883 (8.34e-05)   vel-e 392f1ef4 (1.67e-04)
```

So the rotation is identity *at tick 1* and doing something — wrong, but not nothing — by tick 16.
That is the signature of a **lagged or stale attitude** rather than a hardcoded identity: at tick 1
the previous quaternion *is* the initial identity, which is why tick 1 looks exactly like an
identity rotation.

Stated as a hypothesis jess cannot discharge from outside: distinguishing "reads the previous
tick's quaternion" from other stale-read shapes needs synth's emitted stream read against its
input, which is what these bytes are for.
