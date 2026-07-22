// jess sigil attestation gate driver (DD-023 / REQ-PIX-021 terminal rung).
//
// Drives sigil's wsc-component.wasm (exports wasm-signatures:wasmsign/signing) via a
// wasmtime component host + WASI, to prove the meld-fused falcon core can be SIGNED and
// VERIFIED — the "sigil-signed flashable set" step. keygen -> sign(core) -> verify==true;
// NEGATIVE CONTROL: flip one byte -> verify==false. The signed input is the *reproducible*
// (path-independent, meld#341) fused core, so the signature is over a portable digest.
//
// Usage: sigil-run <wsc-component.wasm> <module-to-sign.wasm>
// Exit 0 only if sign+verify round-trips AND the tampered module fails verification.
use anyhow::{bail, Context, Result};
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Engine, Store};
use wasmtime_wasi::p2::add_to_linker_sync;
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    world: "root",
    path: "wit/wsc.wit",
});

use exports::wasm_signatures::wasmsign::signing::{SignOptions, SignResult};

struct Ctx {
    table: ResourceTable,
    wasi: WasiCtx,
}
impl WasiView for Ctx {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView {
            ctx: &mut self.wasi,
            table: &mut self.table,
        }
    }
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        bail!("usage: sigil-run <wsc-component.wasm> <module-to-sign.wasm>");
    }
    let comp_path = &args[1];
    let module = std::fs::read(&args[2]).with_context(|| format!("read {}", &args[2]))?;

    let engine = Engine::new(wasmtime::Config::new().wasm_component_model(true))?;
    let component =
        Component::from_file(&engine, comp_path).map_err(|e| anyhow::anyhow!("load component {comp_path}: {e}"))?;
    let mut linker: Linker<Ctx> = Linker::new(&engine);
    add_to_linker_sync(&mut linker)?;

    let mut store = Store::new(
        &engine,
        Ctx {
            table: ResourceTable::new(),
            wasi: WasiCtxBuilder::new().inherit_stderr().build(),
        },
    );
    let root = Root::instantiate(&mut store, &component, &linker)?;
    let sig = root.wasm_signatures_wasmsign_signing();

    // 1. keygen
    let kp = sig
        .call_keygen(&mut store)?
        .map_err(|e| anyhow::anyhow!("keygen: {e}"))?;
    eprintln!(
        "keygen: public-key {} bytes, secret-key {} bytes",
        kp.public_key.len(),
        kp.secret_key.len()
    );

    // 2. sign the fused core (detached)
    let opts = SignOptions {
        key_id: None,
        detached: true,
    };
    let signed = sig
        .call_sign(
            &mut store,
            &module,
            &kp.secret_key,
            Some(&kp.public_key),
            &opts,
        )?
        .map_err(|e| anyhow::anyhow!("sign: {e}"))?;
    let detached_sig = match &signed {
        SignResult::Detached(bytes) => bytes.clone(),
        SignResult::Embedded(_) => bail!("expected detached signature, got embedded"),
    };
    eprintln!("sign: detached signature {} bytes", detached_sig.len());

    // 3. verify the genuine module -> must be true
    let ok = sig
        .call_verify(&mut store, &module, &kp.public_key, Some(&detached_sig))?
        .map_err(|e| anyhow::anyhow!("verify(genuine): {e}"))?;
    if !ok {
        bail!("verify(genuine) returned false — sign/verify round-trip broken");
    }
    eprintln!("verify(genuine): true");

    // 4. NEGATIVE CONTROL: flip one byte -> verify must be false
    let mut tampered = module.clone();
    let idx = tampered.len() / 2;
    tampered[idx] ^= 0x01;
    let bad = sig
        .call_verify(&mut store, &tampered, &kp.public_key, Some(&detached_sig))?
        .map_err(|e| anyhow::anyhow!("verify(tampered): {e}"))?;
    if bad {
        bail!("verify(tampered) returned TRUE — signature does not detect a 1-byte tamper (negative control failed)");
    }
    eprintln!("verify(tampered, 1 byte flipped @ {idx}): false");

    println!("SIGIL OK — fused core signed + verified (detached, {} B sig); tamper detected (negative control has teeth).", detached_sig.len());
    Ok(())
}
