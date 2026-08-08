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
- QuickJS omits `deno_image`, `deno_lint`, `deno_doc`, `deno_kv`, and
  `deno_telemetry`. V8 retains those features through its existing feature
  set.
- QuickJS also omits the QUIC/WebTransport implementation and Deno Deploy
  tunnel. V8 retains the networking APIs through the `quic` feature.
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

## Completed: remove QUIC/WebTransport from QuickJS

The QuickJS profile now omits QUIC, WebTransport, and Deno Deploy tunnel
support. The implementation is behind a `quic` feature on `deno_net`,
`deno_http`, `deno_web`, and `deno_runtime`; V8 enables that feature. The
QuickJS runtime does not expose the QUIC/WebTransport globals, and the native
QUIC/tunnel ops and resource variants are not registered.

This is a combined cut rather than a `deno_tunnel`-only deletion: `deno_net`
also directly compiled the QUIC stack, while HTTP and CLI code had tunnel
integration of their own. The main boundary is `ext/net`, with conditional
handling in `ext/http`, the runtime bootstrap globals, and CLI tunnel startup.

### Measured result

The comparison uses the existing `target/macos-aarch64-quickjs` cache and the
`release-quickjs` profile; no target directory was removed or reset.

| Measurement | Before QUIC cut | After QUIC cut | Difference |
| --- | ---: | ---: | ---: |
| Normal/build package IDs | 777 | 767 | -10 (-1.29%) |
| `deno` release binary | 74,571,152 B | 72,883,728 B | -1,687,424 B (-2.26%) |
| `denort` release binary | 48,952,816 B | 47,337,232 B | -1,615,584 B (-3.30%) |
| Combined binaries | 123,523,968 B | 120,220,960 B | -3,303,008 B (-2.67%) |

## Completed: remove isolated runtime and CLI features

The following cuts are explicit QuickJS-only feature boundaries, each kept in
its own commit so they can be rebased or reverted independently:

| Cut | QuickJS package IDs after cut | Change from previous step |
| --- | ---: | ---: |
| WebGPU and coupled Canvas | 831 | -31 |
| `deno_image` | 818 | -13 |
| `deno_lint` | 815 | -3 |
| `deno_doc` | 793 | -22 |
| `deno_kv` and `denokv_*` | 787 | -6 |
| `deno_telemetry` and its QuickJS exporters | 777 | -10 |

`deno_kv` owns `Deno.openKv()`, including the local SQLite backend and the
remote KV protocol. Removing it does not remove SQLite itself: the cache,
Web Storage, and Node SQLite paths still share `rusqlite`.

`deno_telemetry` provides OpenTelemetry-based tracing, metrics, log/event
export, HTTP instrumentation, and `Deno.telemetry`. The QuickJS boundary
keeps the surrounding CLI and HTTP interfaces compiling with no-op fallback
types while omitting the telemetry extension and exporter graph. V8 keeps the
full implementation.

### Final measured result

The final comparison uses the existing `target/macos-aarch64-quickjs` cache
and the `release-quickjs` profile; no target directory was removed or reset.

| Measurement | Before all cuts | After all cuts | Difference |
| --- | ---: | ---: | ---: |
| Normal/build package IDs | 862 | 777 | -85 (-9.86%) |
| `deno` release binary | 92,101,840 B | 74,571,152 B | -17,530,688 B (-19.03%) |
| `denort` release binary | 58,095,968 B | 48,952,816 B | -9,143,152 B (-15.74%) |
| Combined binaries | 150,197,808 B | 123,523,968 B | -26,673,840 B (-17.76%) |

Relative to the WebGPU-only build, the later cuts remove another 54 package
IDs and 15,997,312 B from the combined release binaries (-11.47%).

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

These are recommendations for the `~/d/pi` runtime profile. They are not
changed yet; estimates are graph-level and should be confirmed with one
isolated build each.

1. `deno_ffi` (`Deno.dlopen`) is the strongest next cut. Its QuickJS path
   brings in the Cranelift family, `libffi`, and dynamic-loader glue; the
   current graph shows roughly 15 Cranelift package IDs that are only reached
   through this feature. Expected impact: roughly 15-20 package IDs and about
   1-4 MB per release binary, with medium implementation friction because
   worker initialization and FFI globals/declarations must be gated.

2. QUIC/WebTransport plus the Deno Deploy tunnel is the next potentially
   meaningful backend cut. Pi has no tunnel or WebTransport use, but
   `deno_net` directly compiles both `quinn` and `deno_tunnel`; removing only
   `deno_tunnel` would therefore save little. A useful cut would feature-gate
   `ext/net/quic.rs`, the WebTransport globals, tunnel ops, and the CLI tunnel
   startup path together. This is likely more valuable than the small isolated
   cuts below, but it is a medium/high-friction API boundary and its exact
   binary impact needs an isolated build because some TLS/QUIC dependencies
   are shared with other networking code.

3. `deno_inspector_server` is a plausible cut if pi will never use
   `--inspect` or DevTools connections. It is a runtime/debugging boundary,
   but worker inspector channels and CLI inspector setup need to be gated.
   Expected impact: one workspace package plus roughly 0.5-1.5 MB per release
   binary; implementation friction is medium.

`deno_cron` is a smaller, low-risk API cut if pi does not use `Deno.cron()`.
It is unlikely to produce a dramatic binary reduction, but it is relatively
contained and should remove one workspace package with less coupling than
inspector or FFI. Expected impact: under 0.5 MB per release binary;
implementation friction is low to medium.

## Investigated but not cut

### `deno_napi`

The cited pi commit `656057422528726e954e49f56dc321070f585264` explicitly
skips native `.node` loading under QuickJS, and pi’s runtime source does not
use N-API directly. A temporary feature-gating experiment removed four
QuickJS package IDs (`deno_napi`, `napi_sym`, `libuv-sys-lite`, and one
`libloading` version), but the release link was 890,048 B larger overall
because of linker/layout variation. The change also required touching worker
initialization, finalizers, standalone loader plumbing, and V8 feature wiring.
It was reverted as not worth the friction for this profile.

### `deno_snapshots`

`deno_snapshots` is not V8-only in the QuickJS profile. QuickJS enables its
`disable` feature, which omits the V8 startup blob but still runs the snapshot
crate's build script to generate `EXTENSION_RESIDUAL_SOURCES.rs`. The CLI,
`denort`, and TSC paths consume its `RESIDUAL_LAZY_JS`,
`RESIDUAL_LAZY_ESM`, and `TS_VERSION` exports. Removing the crate would mean
moving that source-table generation and version export into another package;
it would remove only one workspace package and would not remove the generated
runtime source data. This is low-value and higher-friction than the cuts above.

### `deno_ffi`

The current `~/d/pi` source and build paths contain no `Deno.dlopen` or other
Deno FFI usage. However, `deno_runtime` currently initializes the FFI
extension and uses its re-export of the shared `DenoRtNativeAddonLoader` type;
that loader is also used by standalone VFS/native-addon plumbing. Removing
`deno_ffi` would therefore require gating the FFI extension, its JavaScript
surface, loader state, and the Cranelift/`libffi` dependency family. It remains
a plausible next cut for a pi-only profile, but should be isolated separately.

### `deno_webstorage`

Pi’s runtime source does not use `localStorage` or `sessionStorage`, but this
crate is also the current re-export boundary for `rusqlite`. Several CLI cache
modules import `deno_runtime::deno_webstorage::rusqlite` directly, so removing
the Web Storage extension would first require moving those imports to an
explicit CLI SQLite dependency. That is possible, but it is only one workspace
package and does not remove SQLite; it is not a worthwhile minimal cut.

### QUIC/WebTransport and `deno_tunnel`

Pi’s source has no Deno tunnel or WebTransport use. However, `deno_net` always
registers QUIC/WebTransport ops and tunnel ops, and `ext/http` has direct tunnel
stream/error integration. The CLI also owns tunnel authentication and startup.
The tunnel crate is therefore not an isolated dependency removal: a useful
cut would remove or feature-gate the complete QUIC/WebTransport/tunnel surface,
including its declarations and CLI paths. This is a real candidate only if
the pi profile is allowed to lose those Deno APIs.

### SQLite

SQLite is intentionally retained for `~/d/pi`. `deno_node_sqlite` implements
the Node `node:sqlite` API, which pi’s SQLite session backend imports directly.
`deno_cache` and `deno_webstorage` also reach the shared
`rusqlite`/`libsqlite3-sys` stack. SQLite is therefore not a candidate for the
current pi profile.
