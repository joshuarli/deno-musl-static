# Deno native build workflows

The repository builds Deno and `denort` as static Linux musl binaries through
four native Alpine images:

| Architecture | Engine | Dockerfile | Rust target | Artifact prefix |
| --- | --- | --- | --- | --- |
| arm64 | QuickJS | `tools/docker/Dockerfile.alpine-aarch64-musl-quickjs` | `aarch64-alpine-linux-musl` | `*-quickjs-aarch64-unknown-linux-musl` |
| arm64 | V8 | `tools/docker/Dockerfile.alpine-aarch64-musl-v8` | `aarch64-alpine-linux-musl` | `*-v8-aarch64-unknown-linux-musl` |
| amd64 | QuickJS | `tools/docker/Dockerfile.alpine-x86_64-musl-quickjs` | `x86_64-alpine-linux-musl` | `*-quickjs-x86_64-unknown-linux-musl` |
| amd64 | V8 | `tools/docker/Dockerfile.alpine-x86_64-musl-v8` | `x86_64-alpine-linux-musl` | `*-v8-x86_64-unknown-linux-musl` |

The exported files are named, for example,
`deno-quickjs-x86_64-unknown-linux-musl` and
`denort-v8-aarch64-unknown-linux-musl`.

## Image boundaries

The QuickJS Dockerfiles contain only the Alpine packages and Rust/C toolchain
needed for the QuickJS graph. They deliberately do not install GN, Node,
protobuf, or the Rusty V8/Chromium source-build setup. The V8 Dockerfiles add
those tools, apply the Rusty V8 and stacker Alpine overlays, and build V8 from
source.

Both architectures use the pinned LLVM 23.1.0-rc2 musl bundle from release
`llvm-musl-23.1.0-rc2-c72c957`. The amd64 bundle is
downloaded from
[`llvm-prebuilt-musl`](https://github.com/laputa-systems/llvm-prebuilt-musl/releases/download/llvm-musl-23.1.0-rc2-c72c957/clang%2Bllvm-23.1.0-rc2-x86_64-linux-musl.tar.xz)
with SHA-256
`cf90f119fac7e55088e3b718c8a956370d940b004ea5b4f36f629717bc108543`; the
arm64 bundle uses SHA-256
`7b8f4d720bb6b2a40352a1c2f57a55100647cf5083ee9c40c5fd7e804e2570d5`.

## Local builds

The root `Makefile` is the local contract. It builds the selected image with
BuildKit, stores Cargo targets and ccache in named Docker volumes, exports the
two binaries, rejects ELF interpreters and `DT_NEEDED` entries, and can run a
native Alpine smoke test.

On an amd64 host, the locally validated paths are:

```sh
make musl-amd64-quickjs-debug-smoke
make musl-amd64-v8-release-smoke
```

Use `musl-amd64-quickjs-release-smoke` or
`musl-amd64-v8-release-smoke` for optimized builds. The `amd64` Makefile
targets select `linux/amd64` and the `x86_64-alpine-linux-musl` Rust target.

The V8 debug build target remains available for static/toolchain iteration, but
its DEBUG-only embedded-blob compatibility assertion currently rejects the
musl source build at runtime. Runtime acceptance therefore uses the release V8
path, where that upstream DEBUG assertion is not compiled.

Arm64 targets are available with the corresponding `aarch64` architecture
names, but should be run on a native arm64 machine; this checkout does not use
slow arm emulation for local validation.

For macOS 26+ arm64, both engine pairs can be built natively with the regular
macOS allocator and dynamic system libraries:

```sh
make macos-aarch64-quickjs-debug-smoke
make macos-aarch64-quickjs-release-smoke
make macos-aarch64-v8-release-smoke
```

These targets use `aarch64-apple-darwin` and export engine-specific
compiler/runtime pairs under `target/macos-aarch64-{quickjs,v8}-artifacts`.
The QuickJS targets use the `release-quickjs` profile; the V8 target uses the
regular optimized `release` profile. Neither path enables `musl-mimalloc` or
attempts static linking. The QuickJS pair is the one consumed by pi; the V8
pair exists to verify that native macOS V8 remains buildable.

To smoke-test already-exported amd64 artifacts without rebuilding:

```sh
make musl-smoke MUSL_ARCH=x86_64 MUSL_ENGINE=quickjs \
  MUSL_PLATFORM=linux/amd64 MUSL_RUST_TARGET=x86_64-alpine-linux-musl \
  MUSL_ARTIFACT_DIR=target/musl-x86_64-quickjs-artifacts
```

The smoke runs `deno --version`, direct JavaScript for V8, and
`deno compile`; QuickJS compilation explicitly selects the matching
QuickJS `denort` through `DENORT_BIN`.

## GitHub Actions

`.github/workflows/build.yml` has a six-entry matrix. The Linux arm64 entries
run on `ubuntu-24.04-arm`, the amd64 entries on `ubuntu-24.04`, and the macOS
QuickJS/V8 entries on `macos-26`. The workflow checks out the exact
`GITHUB_SHA`, builds release artifacts, archives each binary individually,
uploads twelve ZIPs through the matrix, and publishes those twelve zipped
binaries in the prerelease `deno-<GITHUB_SHA>-linux-musl-static`.

## Linux acceptance checks

For both `deno` and `denort`, the build script requires:

- a Linux ELF executable for the selected architecture;
- no `PT_INTERP` ELF interpreter;
- no `DT_NEEDED` dynamic dependencies; and
- successful execution in the matching native Alpine image.

The standalone output from `deno compile` receives the same static ELF gate.

The shared implementation is `tools/docker/build-alpine-musl.sh`; architecture
and engine-specific toolchain setup belongs in the four Linux Dockerfiles. The
Rusty V8 adjustments are kept in
`tools/docker/rusty-v8-150.4-alpine.patch`, and the musl stacker fixes in
`tools/docker/stacker-0.1.15-alpine.patch`.
