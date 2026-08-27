# jess-authored WIT — the composition worlds

Three WIT trees in this repo, with different provenance and different rules:

| tree | provenance | may be hand-edited? |
|---|---|---|
| `wit/` | **spar codegen from `hardware/pixhawk6x-rt.aadl`** | **no** — CI gates `wit/ == spar codegen` (`tools/wit/regen.sh --check`) |
| `wit-deps/` | **extracted from shipped supplier `.wasm`** | no — re-extract instead |
| `wit-app/` (here) | **authored by jess** | yes — this is the integration surface jess owns |

`wit-app/flight-app` is the mapping between relay's flight cascade and gale's `gust:os`
runtime — the piece AFD-043 identified as missing. It is *not* AADL-derived (it describes a
composition, not the hardware architecture) and *not* extracted (no supplier ships it), so it
belongs in neither of the other two trees.

**This separation was forced by CI, correctly.** The world was first placed in `wit/` and the
derivation gate failed with `WIT-DERIVATION DRIFT — Only in wit/: flight-app`. That gate exists
so a hand-edit cannot masquerade as generated output; the right fix was to move the file, not to
loosen the gate.
