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

The current iteration is deliberately a debug, static-only build of `deno`
(`cargo build`, V8 `is_debug=true`, `-O0`, symbol level 1). `denort` is opt-in
with `--build-arg BUILD_DENORT=1`; release optimization and the second binary
come after this faster feedback loop reaches a clean link.

The build has already established these facts:

- Alpine's native arm64 Rust target is `aarch64-alpine-linux-musl`.
- Rusty V8 150.4.0 has no prebuilt archive for that target.
- An unmodified source build attempts to install a Debian arm64 sysroot.
- The downstream Rusty V8 overlay disables that sysroot and uses Alpine's
  system Rust toolchain.
- GN generation is reachable; the remaining work is toolchain/runtime
  integration and then the final Deno link.

Latest probe result:

- The debug V8 action graph reached 360 of 687 compile actions in its current
  target graph. The Clang-22 flag overlay and static archive search path were
  applied, and the prior helper-link failure for `libc++abi.a` and
  `libunwind.a` is resolved.
- ccache is active: generated V8 commands invoke `/usr/bin/ccache` before the
  pinned LLVM compiler, and BuildKit persists its `/ccache` cache mount.
- The sanitizer callback overlay now handles V8's trap-only hardening without
  adding sanitizer headers or runtimes.
- The run next stopped at V8's debug-only `execinfo.h` include. The source
  overlay now limits that optional symbolization helper to environments that
  provide it; the next run will test the remaining V8 and Deno graph.
- No final `deno` ELF has been produced yet, so no artifact is considered
  buildable.

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
  is tied to the LLVM archive digest, and BuildKit persists both the ccache data
  and Cargo's `target/` directory across rebuilds.
- The debug probe applies `tools/docker/deno-static-debug.patch` only when
  `BUILD_DENORT=0`. It removes the unused host-side build dependency graph and
  makes the `denort`-only linker-flag build script a no-op; the normal target
  V8 dependency remains unchanged. This keeps the first Deno binary iteration
  from compiling a second host V8.

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
| `deno-static-debug.patch` | Local `BUILD_DENORT=0` iteration overlay: removes the unused host-side V8 graph and skips `denort`-only linker-flag generation so the probe builds V8 once for the target. |
| `v8-use-system-icu.patch` | Not applied: this probe keeps the version-matched ICU data embedded in Rusty V8 while the static ICU/link contract is established. |
| `use-system-libs.patch` | Not applied yet: system-library selection changes SQLite, zstd, libffi, and lcms2 link inputs and must be tested as static archives, not assumed from the Alpine shared-library recipe. |
| `unbundle-ca-certs.patch` | Not a build-portability prerequisite; deferred as a separate certificate/runtime policy decision. |
| `cargo.lock.patch` | Not copied: it removes registry provenance for Alpine-local source overlays and downgrades psm; the current lock is for Rusty V8 150.4.0 and stacker 0.1.15. |
| `tests-*` patches | Deferred until the native binary builds; they affect test execution and test fixtures, not the first artifact link. |

## Immediate next judge

Run the native debug build:

```sh
docker buildx build --platform linux/arm64 --progress=plain \
  --build-arg V8_FROM_SOURCE=1 \
  --build-arg BUILD_DENORT=0 \
  -t deno-alpine-aarch64-musl-probe \
  -f tools/docker/Dockerfile.alpine-aarch64-musl .
```

Export without a macOS bind mount. The image copies checked binaries into a
named-volume-backed `/artifacts` directory:

```sh
docker volume create deno-aarch64-musl-artifacts
docker run --rm --platform linux/arm64 \
  --mount type=volume,source=deno-aarch64-musl-artifacts,target=/artifacts \
  deno-alpine-aarch64-musl-probe
docker create --name deno-aarch64-musl-copy \
  --mount type=volume,source=deno-aarch64-musl-artifacts,target=/artifacts \
  alpine:latest
docker cp deno-aarch64-musl-copy:/artifacts/deno-aarch64-unknown-linux-musl .
docker rm deno-aarch64-musl-copy
```

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

- Port Alpine's stacker/psm changes as version-pinned Cargo registry overlays
  if stack-overflow detection fails on musl.
- Add musl targets to Deno's `deno compile` target mapping after the native
  binary itself links successfully.
- Add focused artifact and target-mapping tests before treating the build as
  release-ready.

## Acceptance criteria

- `deno` and `denort` are arm64 ELF executables.
- Neither has an ELF interpreter or `DT_NEEDED` entry.
- No compiler, linker, or runtime dependency selects another libc.
- `deno --version` and a minimal JavaScript execution pass in native Alpine
  arm64.
- `deno compile --target=aarch64-unknown-linux-musl` produces the same static
  target contract.
