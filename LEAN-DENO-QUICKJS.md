# Lean QuickJS build

This document tracks build-graph reductions for the macOS `aarch64` QuickJS
build. The goal is a small, isolated QuickJS profile that is easy to rebase on
upstream. V8 builds should retain their existing behavior.

## Current state

- The QuickJS backend is `v8x`; `rusty_v8` is not in the resolved graph.
- `deno_runtime` is required. It is the runtime used by both `deno` and
  `denort`, including the QuickJS worker, permissions, filesystem, networking,
  and Node compatibility layers.
- `deno_napi` is a real runtime dependency, not just a linker helper. Workers
  initialize it and the CLI uses it for Node-API native addon loading. Removing
  it would remove native addon support from the QuickJS binary.
- `deno_telemetry` is still enabled and is intentionally deferred.
- The macOS Makefile now builds `deno` and `denort` in one Cargo invocation,
  allowing Cargo to share their resolved build units. The `deno` build script
  no longer depends on `deno_runtime` just to reach linker-flag helpers.

The existing `target/macos-aarch64-quickjs` cache must be preserved while
working on this effort. Cold-build measurements are out of scope for now.

## Completed: remove WebGPU from QuickJS

The QuickJS profile now omits the WebGPU implementation and its transitive
`wgpu-*`/`naga` dependency family at compile time. Canvas is omitted with it
because the current `deno_canvas` implementation is coupled directly to
WebGPU; preserving 2D Canvas would require a separate backend split.

The main coupling points are:

- `runtime/Cargo.toml`: unconditional `deno_webgpu` and `deno_canvas`
  dependencies.
- `runtime/shared.rs`, `runtime/worker.rs`, `runtime/web_worker.rs`,
  `runtime/snapshot_files.rs`, and `runtime/snapshot_info.rs`: WebGPU and
  Canvas extension registration for workers and snapshots.
- `runtime/ops/desktop.rs`: WebGPU-backed desktop/canvas surface types.
- `runtime/js/90_deno_ns.js`, `runtime/js/98_global_scope_shared.js`,
  `runtime/js/98_global_scope_window.js`, and
  `runtime/js/98_global_scope_worker.js`: WebGPU globals and lazy extension
  loading.
- `cli/snapshot/build.rs` and `cli/tsc/mod.rs`: snapshot sources and WebGPU
  declaration files.
- `cli/ops/jupyter.rs`: direct WebGPU types used by Jupyter display helpers.
- `ext/canvas`: its implementation depends directly on `deno_webgpu`, so a
  minimal removal may drop the Canvas extension from QuickJS as well. Keeping
  non-WebGPU Canvas would require splitting that crate's backend boundary.
- `cli/build.rs` and `cli/rt/build.rs`: platform linker-helper calls that must
  remain correct for V8 while being omitted where the lean QuickJS profile no
  longer links WebGPU.

### Boundary implemented

An explicit runtime `webgpu` feature is enabled by V8 and omitted by QuickJS.
The dependency edges, Rust extension lists, snapshot inputs, JavaScript
globals, declaration assets, Jupyter helpers, and desktop surface code follow
that feature. The QuickJS build does not leave a WebGPU stub dependency or a
half-registered extension behind.

The QuickJS contract after this change should be explicit:

- no `deno_webgpu`, `wgpu-*`, or `naga` packages in the QuickJS graph;
- no `navigator.gpu`, WebGPU globals, or `Deno.unstable.webgpu` implementation;
- no WebGPU-backed Canvas surface path unless Canvas is separately split;
- V8 builds remain unchanged.

### Measured result

The comparison used the existing
`target/macos-aarch64-quickjs` directory. The baseline was captured before
the WebGPU change and the after-build used the same
`release-quickjs` profile; this is not a cold-build benchmark.

| Measurement | Before | After | Difference |
| --- | ---: | ---: | ---: |
| Normal/build package IDs | 862 | 831 | -31 (-3.60%) |
| `deno` release binary | 92,101,840 B | 86,638,704 B | -5,463,136 B (-5.93%) |
| `denort` release binary | 58,095,968 B | 52,882,576 B | -5,213,392 B (-8.97%) |
| Combined binaries | 150,197,808 B | 139,521,280 B | -10,676,528 B (-7.11%) |

The removed package set includes `deno_webgpu`, `deno_canvas`, `naga`,
`wgpu-core`, `wgpu-hal`, `wgpu-naga-bridge`, `wgpu-types`, the Apple Metal
backend packages, and their supporting packages. The package count is modest,
but those crates contain substantial native/backend code, which explains the
larger binary reduction.

The release QuickJS smoke test reports `undefined` for
`navigator.gpu`, `GPU`, `OffscreenCanvas`, and `Deno.unstable?.webgpu`.

### Validation

Use the existing target directory and run focused checks:

```sh
cargo tree --locked --target aarch64-apple-darwin \
  -p deno -p denort --no-default-features --features quickjs -e normal,build

cargo build --locked --target aarch64-apple-darwin \
  --target-dir target/macos-aarch64-quickjs \
  -p deno -p denort --no-default-features --features quickjs
```

The graph check must show no WebGPU/wgpu packages, and the combined build must
continue to produce both binaries. Do not delete or recreate the target cache.

## Next-step candidates

These are recommendations for the `~/d/pi` runtime profile; no additional
candidate has been changed yet.

1. `deno_lint` and `deno_doc` are the cleanest CLI-only cuts. They are pulled
   by `cli/Cargo.toml` for the `lint`/`doc` commands and related LSP support,
   not by the runtime extension graph. A small `lean-runtime` feature could
   omit those commands and LSP providers together. This should remove more
   compile-time and binary weight than another individual browser API, with
   the explicit tradeoff that `deno lint`, `deno doc`, and their LSP features
   disappear from this profile.

2. `deno_image` is a relatively contained browser API cut. It implements
   `ImageBitmap`/`createImageBitmap` and pulls the Rust `image` codec family;
   QuickJS already no longer needs its WebGPU/Jupyter path. Making it an
   optional runtime feature would require gating the image extension,
   `ImageBitmap` globals, and declarations, but is still a straightforward
   follow-up.

3. KV is probably the next larger runtime cut, but it has more coupling than
   its lazy JS API suggests. `deno_kv` supplies `Deno.openKv()` and currently
   initializes a local SQLite backend plus a remote HTTP backend through
   `denokv_proto`, `denokv_sqlite`, and `denokv_remote`. Removing it can drop
   that denokv family and its protocol/remote code, but it will not remove all
   SQLite: `deno_cache`, Web Storage, and Node SQLite also use `rusqlite`.
   The safe shape is another explicit runtime feature, then gating worker
   initialization, the lazy `01_db.ts` module, unstable KV declarations, and
   the related CLI/storage plumbing.

4. `deno_telemetry` remains deferred. It has a broader configuration,
   HTTP/logging, bootstrap, and exporter surface than these candidates, so it
   is better handled after the isolated runtime cuts are measured.

## Deferred task: remove telemetry

`deno_telemetry` provides:

- the `Deno.telemetry` tracer, meter, and span runtime extension;
- HTTP request metrics and tracing in `ext/http`;
- CLI logging, bootstrap configuration, standalone metadata, and error-event
  integration;
- OTLP HTTP, custom gRPC, and console exporters with `OTEL_*` configuration.

Its initialization is a runtime no-op when tracing, metrics, and console
capture are disabled, but the implementation and OpenTelemetry dependency
family still compile. Removing it requires a separate feature boundary across
`runtime`, `ext/http`, CLI bootstrap/configuration, and logging. Keep this out
of the WebGPU change so the QuickJS reduction remains easy to rebase and test.
