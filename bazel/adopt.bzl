"""adopt_wasm_component — wrap a prebuilt external .wasm component into the
rules_wasm_component graph (WasmComponentInfo) so wasm_validate / wasm_optimize
can consume a released artifact (e.g. relay's falcon-flight.wasm).

This is the downstream-integration shim jess needs because rules_wasm_component
has no "adopt prebuilt component" rule yet (see rules_wasm_component#489).
"""

load("@rules_wasm_component//providers:providers.bzl", "WasmComponentInfo")

def _adopt_wasm_component_impl(ctx):
    f = ctx.file.wasm
    return [
        DefaultInfo(files = depset([f])),
        WasmComponentInfo(
            wasm_file = f,
            wit_info = None,
            component_type = "component",
            imports = [],
            exports = [],
            metadata = {"adopted": "true", "name": ctx.label.name},
            profile = "release",
            profile_variants = {},
        ),
    ]

adopt_wasm_component = rule(
    implementation = _adopt_wasm_component_impl,
    doc = "Adopt a prebuilt .wasm component as a WasmComponentInfo target.",
    attrs = {
        "wasm": attr.label(allow_single_file = [".wasm"], mandatory = True),
    },
)
