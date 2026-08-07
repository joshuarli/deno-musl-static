#!/bin/sh
set -eu

# Build a debug Deno CLI first. The optional denort build is enabled explicitly
# once the faster single-binary iteration reaches the link and ELF checks.
RUST_TARGET="${RUST_TARGET:-${CARGO_BUILD_TARGET:?CARGO_BUILD_TARGET must be set}}"

if [ -d target ]; then
  find target -type d -name 'stacker-*' -prune -exec rm -rf '{}' +
  find target -type f \( -name 'libstacker-*' -o -name 'stacker-*' \) -delete
fi

RUSTFLAGS="-C linker=clang++ -C link-arg=-fuse-ld=lld -C target-feature=+crt-static" \
  cargo build --locked -p deno --bin deno
if [ "${BUILD_DENORT}" = 1 ]; then
  RUSTFLAGS="-C linker=clang++ -C link-arg=-fuse-ld=lld -C target-feature=+crt-static" \
    cargo build --locked -p denort --bin denort
fi

for binary in deno; do
  path="target/${RUST_TARGET}/debug/${binary}"
  file "${path}"
  readelf -lW "${path}"
  readelf -dW "${path}" || true
  if readelf -lW "${path}" | grep -q 'INTERP'; then
    echo "ERROR: static ${binary} unexpectedly has an ELF interpreter" >&2
    exit 1
  fi
  if readelf -dW "${path}" | grep -q 'NEEDED'; then
    echo "ERROR: static ${binary} unexpectedly has dynamic dependencies" >&2
    exit 1
  fi
done

if [ "${BUILD_DENORT}" = 1 ]; then
  path="target/${RUST_TARGET}/debug/denort"
  file "${path}"
  if readelf -lW "${path}" | grep -q 'INTERP' || readelf -dW "${path}" | grep -q 'NEEDED'; then
    echo "ERROR: static denort has dynamic ELF metadata" >&2
    exit 1
  fi
fi

mkdir -p /artifacts
cp "target/${RUST_TARGET}/debug/deno" /artifacts/deno-aarch64-unknown-linux-musl
chmod +x /artifacts/deno-aarch64-unknown-linux-musl
if [ "${BUILD_DENORT}" = 1 ]; then
  cp "target/${RUST_TARGET}/debug/denort" /artifacts/denort-aarch64-unknown-linux-musl
  chmod +x /artifacts/denort-aarch64-unknown-linux-musl
fi

ccache --show-stats
