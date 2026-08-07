#!/bin/sh
set -eu

# Build debug Deno and denort variants. QuickJS is built separately because the
# engine feature changes the complete Rust/C engine graph and each binary needs
# a distinct artifact name.
RUST_TARGET="${RUST_TARGET:-${CARGO_BUILD_TARGET:?CARGO_BUILD_TARGET must be set}}"
RUSTFLAGS="-C linker=clang++ -C link-arg=-fuse-ld=lld -C target-feature=+crt-static"

if [ -d target ]; then
  find target -type d -name 'stacker-*' -prune -exec rm -rf '{}' +
  find target -type f \( -name 'libstacker-*' -o -name 'stacker-*' \) -delete
fi

build_binary() {
  package="$1"
  feature_set="$2"
  artifact_name="$3"

  if [ "${feature_set}" = quickjs ]; then
    RUSTFLAGS="${RUSTFLAGS}" cargo build --locked -p "${package}" --bin "${package}" \
      --no-default-features --features quickjs
  else
    RUSTFLAGS="${RUSTFLAGS}" cargo build --locked -p "${package}" --bin "${package}"
  fi

  path="target/${RUST_TARGET}/debug/${package}"
  file "${path}"
  readelf -lW "${path}"
  readelf -dW "${path}" || true
  if readelf -lW "${path}" | grep -q 'INTERP'; then
    echo "ERROR: static ${artifact_name} unexpectedly has an ELF interpreter" >&2
    exit 1
  fi
  if readelf -dW "${path}" | grep -q 'NEEDED'; then
    echo "ERROR: static ${artifact_name} unexpectedly has dynamic dependencies" >&2
    exit 1
  fi

  mkdir -p /artifacts
  cp "${path}" "/artifacts/${artifact_name}"
  chmod +x "/artifacts/${artifact_name}"
}

build_binary deno v8 deno-aarch64-unknown-linux-musl
if [ "${BUILD_DENORT}" = 1 ]; then
  build_binary denort v8 denort-aarch64-unknown-linux-musl
fi
if [ "${BUILD_QUICKJS}" = 1 ]; then
  build_binary deno quickjs deno-quickjs-aarch64-unknown-linux-musl
  if [ "${BUILD_DENORT}" = 1 ]; then
    build_binary denort quickjs denort-quickjs-aarch64-unknown-linux-musl
  fi
fi

ccache --show-stats
