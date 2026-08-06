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

- The debug V8 action graph reached its generated helper links after the
  Clang-22 flag overlay and static archive search path were applied. The prior
  helper-link failure for `libc++abi.a` and `libunwind.a` is therefore resolved.
- The run was stopped during the long native V8 compile before it produced a
  final `deno` ELF. No artifact is considered buildable yet.

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

## Immediate next judge

Run the native debug build:

```sh
docker buildx build --platform linux/arm64 --progress=plain \
  --build-arg V8_FROM_SOURCE=1 \
  --build-arg BUILD_DENORT=0 \
  -t deno-alpine-aarch64-musl-probe \
  -f tools/docker/Dockerfile.alpine-aarch64-musl .
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

- Apply the current V8 no-`execinfo` patch to the Rusty V8 source tree if the
  V8 compile reaches that code.
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
