# Static aarch64 musl build

This document tracks the work required to produce a Deno `aarch64` Linux
binary linked entirely against musl with no dynamic ELF dependencies. The
artifact target is `aarch64-alpine-linux-musl` during the build and is named
`aarch64-unknown-linux-musl` when exported for consumers.

## Current state

The native build probe is [tools/docker/Dockerfile.alpine-aarch64-musl](tools/docker/Dockerfile.alpine-aarch64-musl).
It uses `alpine:latest`, native arm64 execution, Rust, GN, samurai, and the
pinned LLVM 22.1.8 musl bundle from
[`laputa-systems/llvm-prebuilt-musl`](https://github.com/laputa-systems/llvm-prebuilt-musl).
That bundle supplies the static C++ runtime archives and compiler-rt builtins
that Alpine's compiler packages do not provide together.

The probe rejects a static artifact if either `deno` or `denort` has an ELF
interpreter or a `NEEDED` entry. It does not accept a substitute libc or a
runtime dependency as a shipping path.

The current verified probe is a debug, static-only QuickJS build (`cargo build`,
unoptimized Rust, debug symbols). It is scoped to `deno` and `denort`, because
`denort` is the runtime used by `deno compile`. Release optimization is a
separate `BUILD_PROFILE=release` path.

The build has already established these facts:

- Alpine's native arm64 Rust target is `aarch64-alpine-linux-musl`.
- Rusty V8 150.4.0 has no prebuilt archive for that target.
- An unmodified source build attempts to install a Debian arm64 sysroot.
- The downstream Rusty V8 overlay disables that sysroot and uses Alpine's
  system Rust toolchain.
- GN generation is reachable; the remaining work is toolchain/runtime
  integration and then the final Deno link.

Latest core probe result:

- The single-graph debug build compiled V8 and reached the Deno snapshot build.
  The prior helper-link failure for `libc++abi.a` and `libunwind.a` is resolved.
- ccache is active: generated V8 commands invoke `/usr/bin/ccache` before the
  pinned LLVM compiler. The compiler now runs at container runtime, with ccache
  and Rust's `target/` directory mounted from named Docker volumes.
- The sanitizer callback overlay now handles V8's trap-only hardening without
  adding sanitizer headers or runtimes.
- The V8 debug-only `execinfo.h` include and the stacker stack-pointer
  underflow are now covered by source overlays. The latest run reached the
  snapshot build, but reused an unpatched stacker artifact from the persistent
  Cargo target cache; the Docker setup now invalidates only stacker's
  fingerprints and build products after applying the overlay.
- The core `deno` debug binary is an aarch64 static PIE with no ELF interpreter
  or `DT_NEEDED` entry and `deno --version` runs in native Alpine arm64.
- `deno eval` on the V8 debug graph still reaches V8's embedded-blob
  compatibility check; V8 is outside the scoped artifact contract.
- The QuickJS graph builds both scoped artifacts. Both pass the static ELF gate,
  `deno --version` runs in native Alpine arm64, and `deno compile --engine
  quickjs` emits a static standalone binary that executes `console.log(42)`.
- QuickJS compile warns and disables Deno's V8-based type checker because the
  `deno_cli_tsc` extension is V8-specific. V8 compile behavior is unchanged.
- The optimized release profile now uses thin LTO with Cargo's default release
  codegen parallelism; it no longer uses the single-codegen-unit fat-LTO setup.
- The release artifacts passed the same static gate and native Alpine smoke:
  `deno` is 248,022,488 bytes and `denort` is 164,881,856 bytes. A release
  `deno compile --engine quickjs` output executed and printed `42`.

## Ported changes

- Deno's allocator-trimming and `SIGUSR2` paths are limited to the GNU Linux
  environment; musl builds use the existing no-op path.
- `tools/docker/rusty-v8-150.4-alpine.patch` ports the current Alpine V8
  changes that are relevant to this dependency version:
  - no Debian sysroot for musl aarch64;
  - system Rust metadata instead of downloading Chromium's Rust toolchain;
  - Alpine's aarch64 musl target in V8 compiler configuration;
  - Alpine-compatible compiler-runtime directory selection.
- Clang 22 does not accept three flags currently emitted by V8 150.4.0:
  `-fdiagnostics-show-inlining-chain`, `-fno-lifetime-dse`, and
  `-fsanitize-ignore-for-ubsan-feature=<name>`. The overlay removes only these
  flags for the LLVM 22 probe. Restore them when the pinned LLVM bundle is
  upgraded to a version that supports them.
- The static C++ archive directory is exported as `/opt/llvm-musl/lib` so V8's
  helper links can resolve the bundle's `libc++abi.a` and `libunwind.a`.
- The Docker environment supplies explicit target and host compiler, linker,
  archiver, symbol, and binary utility paths, following the hermetic Chromium
  musl build at `/Users/josh/d/chromium-portable-hermetic-musl-build`.
- It also uses `/usr/bin/ccache` for V8's compile actions. The ccache namespace
  is tied to the LLVM archive digest. The image prepares the source and toolchain;
  the runtime build mounts `deno-aarch64-musl-target` at Cargo's `target/`,
  `deno-aarch64-musl-ccache` at `/ccache`, and
  `deno-aarch64-musl-artifacts` at `/artifacts`. This avoids macOS bind mounts
  for all build outputs and keeps the Rust target cache inspectable and reusable.
- QuickJS embeds eager extension sources at compile time and generates a
  transpiled residual-source table without a V8 startup blob. V8 retains its
  normal snapshot path.
- The MUSL argv-buffer initializer is restricted to glibc Linux. MUSL static
  standalone binaries do not receive argc/argv arguments in `.init_array`
  callbacks, so the glibc-only process-title initializer avoids startup
  corruption.
- The runtime builder is scoped to two artifacts:
  `deno-quickjs-aarch64-unknown-linux-musl` and
  `denort-quickjs-aarch64-unknown-linux-musl`.
- `zlib-static` is part of the Alpine image contract. `zlib-dev` alone provides
  the shared `libz.so` linker name, while the static build requires Alpine's
  validated `/usr/lib/libz.a` archive.

## Alpine Deno patch reconciliation

Alpine's current `community/deno` recipe is for Deno 2.7.4 and Rusty V8
146.1.0. This checkout is on Rusty V8 150.4.0, so the inventory below records
behavior rather than applying old patches by filename.

| Alpine patch | Status in this build |
| --- | --- |
| `musl-malloc_trim.patch` | Already present in the Deno Rust sources; GNU-Linux-only allocator trimming and `SIGUSR2` handling. |
| `stacker-detect-stack-overflow.patch` | Applied through `tools/docker/stacker-0.1.15-alpine.patch`. |
| `stacker-disable-guess_os_stack_limit.patch` | Applied through the same stacker overlay; musl avoids the Linux pthread stack-limit guess. |
| `v8-no-execinfo.patch` | Covered by `tools/docker/rusty-v8-150.4-alpine.patch`; debug symbolization falls back to V8's unresolved marker. |
| `v8-build.patch` | Partially superseded: this probe disables sysroot/download paths, uses system Rust, and uses the pinned Laputa LLVM bundle. Its Alpine system-library link additions remain under evaluation because this build must link static archives. |
| `v8-compiler.patch` | Aarch64 musl target/runtime paths are ported; the split-threshold compiler workaround is also removed. Other architecture hunks are outside this probe. |
| `disable-core-defaults.patch` | Already present in the workspace dependency declaration; `deno_core` selects only `reactor-tokio` and the explicit custom-libc++ feature. |
| `deno-static-debug.patch` | Removed after the feature split became source-native: QuickJS and V8 now select their own snapshot/build-dependency graphs directly. |
| `v8-use-system-icu.patch` | Not applied: this probe keeps the version-matched ICU data embedded in Rusty V8 while the static ICU/link contract is established. |
| `use-system-libs.patch` | Not applied yet: system-library selection changes SQLite, zstd, libffi, and lcms2 link inputs and must be tested as static archives, not assumed from the Alpine shared-library recipe. |
| `unbundle-ca-certs.patch` | Not a build-portability prerequisite; deferred as a separate certificate/runtime policy decision. |
| `cargo.lock.patch` | Not copied: it removes registry provenance for Alpine-local source overlays and downgrades psm; the current lock is for Rusty V8 150.4.0 and stacker 0.1.15. |
| `tests-*` patches | Deferred until the native binary builds; they affect test execution and test fixtures, not the first artifact link. |

## Immediate next judge

Build the prepared image. Compilation happens when the image runs so the Rust
target and ccache data can live in named Docker volumes:

```sh
docker buildx build --platform linux/arm64 --progress=plain \
  --build-arg V8_FROM_SOURCE=1 \
  --build-arg BUILD_DENORT=1 \
  --build-arg BUILD_QUICKJS=1 \
  -t deno-alpine-aarch64-musl-probe \
  -f tools/docker/Dockerfile.alpine-aarch64-musl \
  --load .
```

Create the persistent build volumes and run without macOS bind mounts:

```sh
docker volume create deno-aarch64-musl-target
docker volume create deno-aarch64-musl-ccache
docker volume create deno-aarch64-musl-artifacts
docker create --name deno-aarch64-musl-build --platform linux/arm64 \
  --mount type=volume,source=deno-aarch64-musl-target,target=/src/deno/target \
  --mount type=volume,source=deno-aarch64-musl-ccache,target=/ccache \
  --mount type=volume,source=deno-aarch64-musl-artifacts,target=/artifacts \
  deno-alpine-aarch64-musl-probe
docker start -a deno-aarch64-musl-build
```

The target and ccache volumes persist across image rebuilds and can be
inspected with `docker volume inspect`. Export the checked artifact separately:

```sh
docker create --name deno-aarch64-musl-copy \
  --mount type=volume,source=deno-aarch64-musl-artifacts,target=/artifacts \
  alpine:latest
docker cp deno-aarch64-musl-copy:/artifacts/deno-aarch64-unknown-linux-musl .
```

The Cargo registry is currently prepared in the image because the V8 and
stacker source overlays are applied there. The named `target/` volume is the
important incremental Rust state; a separately seeded registry volume can be
added once the dependency overlay lifecycle is stable.

To smoke-test the compile path with the QuickJS runtime, use the matching
QuickJS denort explicitly. `DENORT_BIN` is the development hook used by the
standalone writer:

```sh
docker create --name deno-aarch64-musl-quickjs-smoke --platform linux/arm64 \
  --mount type=volume,source=deno-aarch64-musl-artifacts,target=/artifacts \
  alpine:latest sh -lc '
    printf "console.log(42)\\n" > /tmp/hello.ts
    DENORT_BIN=/artifacts/denort-quickjs-aarch64-unknown-linux-musl \
      /artifacts/deno-quickjs-aarch64-unknown-linux-musl compile \
      --engine quickjs --output /tmp/hello /tmp/hello.ts
    /tmp/hello
  '
docker start -a deno-aarch64-musl-quickjs-smoke
```

The expected output is `42`. The generated `/tmp/hello` must then be checked
with the same `readelf` static-ELF gate before treating QuickJS `deno compile`
as complete.

The next failure should be classified at the narrowest layer:

1. GN configuration and target triples.
2. V8 source portability, especially stack tracing and `execinfo.h`.
3. Static C++ runtime or compiler-rt archive selection.
4. Deno/Rust native libraries.
5. Final ELF inspection and execution on Alpine arm64.

Do not paper over a linker failure by adding an untracked shared dependency.
Any required system archive must be present in the pinned toolchain or be
validated as a static musl archive before it enters the build contract.

## Remaining porting candidates

- Add musl targets to Deno's `deno compile` target mapping if the upstream
  target surface is expanded beyond the current QuickJS integration path.
- Add focused artifact and target-mapping tests if this work is promoted from a
  repository-local release build into Deno's general release matrix.

## Acceptance criteria

- `deno` and `denort` are arm64 ELF executables.
- Neither has an ELF interpreter or `DT_NEEDED` entry.
- No compiler, linker, or runtime dependency selects another libc.
- `deno --version` and a minimal QuickJS-backed JavaScript execution pass in
  native Alpine arm64.
- `deno compile --target=aarch64-unknown-linux-musl` produces the same static
  target contract.

## Debug and release build commands

The prepared image `deno-alpine-aarch64-musl-probe` builds only the scoped
QuickJS artifacts. `BUILD_PROFILE=debug` is the supported debug pathway;
`BUILD_PROFILE=release` selects Cargo release optimization and
`is_debug=false`/symbol level 0 for the native engine configuration. The
QuickJS source embedding and no-V8-snapshot path are engine-specific; V8's
normal snapshot feature remains available outside this scoped build.

The named Docker volumes are:

- `deno-aarch64-musl-target`, mounted at `/src/deno/target`;
- `deno-aarch64-musl-quickjs-target`, mounted at `/src/deno/target-quickjs`;
- `deno-aarch64-musl-ccache`, mounted at `/ccache`;
- `deno-aarch64-musl-artifacts`, mounted at `/artifacts`.

Run the debug build from the repository root:

```sh
docker create --name deno-aarch64-musl-quickjs-build --platform linux/arm64 \
  --mount type=volume,source=deno-aarch64-musl-target,target=/src/deno/target \
  --mount type=volume,source=deno-aarch64-musl-quickjs-target,target=/src/deno/target-quickjs \
  --mount type=volume,source=deno-aarch64-musl-ccache,target=/ccache \
  --mount type=volume,source=deno-aarch64-musl-artifacts,target=/artifacts \
  deno-alpine-aarch64-musl-probe sh -c '/usr/local/bin/build-alpine-aarch64-musl'
docker start -a deno-aarch64-musl-quickjs-build
```

The builder inspects each binary and copies the verified files to `/artifacts`
as:

```text
denort-quickjs-aarch64-unknown-linux-musl
deno-quickjs-aarch64-unknown-linux-musl
```

Then run the native debug smoke test. Eager QuickJS extension sources are
embedded, so the execution container does not need the build-time source tree.

```sh
docker create --name deno-aarch64-musl-quickjs-smoke-verified --platform linux/arm64 \
  --mount type=volume,source=deno-aarch64-musl-artifacts,target=/artifacts \
  alpine:latest sh -c '
    printf "console.log(42)\\n" > /tmp/hello.ts
    DENORT_BIN=/artifacts/denort-quickjs-aarch64-unknown-linux-musl \
      /artifacts/deno-quickjs-aarch64-unknown-linux-musl compile \
      --engine quickjs --output /tmp/hello /tmp/hello.ts
    /tmp/hello
    file /tmp/hello
    readelf -lW /tmp/hello
    readelf -dW /tmp/hello
  '
docker start -a deno-aarch64-musl-quickjs-smoke-verified
```

For the optimized release build, rebuild the image with release settings and
run the same builder command:

```sh
docker build --platform linux/arm64 \
  --build-arg BUILD_PROFILE=release \
  --build-arg V8_DEBUG=false \
  --build-arg V8_SYMBOL_LEVEL=0 \
  -t deno-alpine-aarch64-musl-release \
  -f tools/docker/Dockerfile.alpine-aarch64-musl .
docker create --name deno-aarch64-musl-quickjs-release-build \
  --platform linux/arm64 \
  --mount type=volume,source=deno-aarch64-musl-target,target=/src/deno/target \
  --mount type=volume,source=deno-aarch64-musl-quickjs-target,target=/src/deno/target-quickjs \
  --mount type=volume,source=deno-aarch64-musl-ccache,target=/ccache \
  --mount type=volume,source=deno-aarch64-musl-artifacts,target=/artifacts \
  deno-alpine-aarch64-musl-release sh -c \
  '/usr/local/bin/build-alpine-aarch64-musl'
docker start -a deno-aarch64-musl-quickjs-release-build
```

Build and smoke-test containers are intentionally named and retained. Reuse
them with `docker start -a <name>` and inspect failures with `docker logs
<name>`; remove a container only as an explicit cleanup decision after its
logs are no longer needed.

`tools/docker/build-alpine-aarch64-musl.sh` uses `target-quickjs`, supports
debug and release profiles, invalidates the stacker cache, and exports only the
two QuickJS artifacts. Keep the target volume separate from host Cargo output;
`.dockerignore` excludes local target trees from the image context.

The optimized release gate is complete for the scoped QuickJS artifacts. The
release `deno` and matching `denort` were then used to build `pi-deno` from
`/Users/josh/d/pi` with `Dockerfile.deno`. That integration build passed in a
native Alpine arm64 container: `pi --version`, `pi --help`, the static ELF
gate, and the embedded-assets/cache smoke all passed. The pi artifact is
named `pi-003aadff9-deno-2.9.5-linux-arm64-musl-static` for that source
revision.

The pi Docker build uses esbuild outside the package ancestry, then lowers the
bundle to CommonJS before `deno compile`. This is deliberate: the ESM bundle
retains bare Node built-in imports and dependency-looking JSDoc imports that
the standalone Deno resolver would otherwise try to resolve. The preparation
step also supplies a stable `import.meta` file URL and lowers dynamic imports
for the QuickJS runtime. `deno desktop` validation is outside this build's
scope.
