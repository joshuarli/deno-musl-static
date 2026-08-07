#!/bin/sh
set -eu

# Build the scoped QuickJS Deno and denort variants. The engine feature changes
# the complete Rust/C graph, so it has its own persistent Cargo target tree.
RUST_TARGET="${RUST_TARGET:-${CARGO_BUILD_TARGET:?CARGO_BUILD_TARGET must be set}}"
RUSTFLAGS="-C linker=clang++ -C link-arg=-fuse-ld=lld -C target-feature=+crt-static"
BUILD_PROFILE="${BUILD_PROFILE:-debug}"

case "${BUILD_PROFILE}" in
  debug)
    PROFILE_DIR=debug
    PROFILE_ARGS=
    ;;
  release)
    PROFILE_DIR=release
    PROFILE_ARGS=--release
    ;;
  *)
    echo "ERROR: BUILD_PROFILE must be debug or release" >&2
    exit 1
    ;;
esac

invalidate_stacker_cache() {
  target_dir="$1"
  if [ -d "${target_dir}" ]; then
    find "${target_dir}" -type d -name 'stacker-*' -prune -exec rm -rf '{}' +
    find "${target_dir}" -type f \( -name 'libstacker-*' -o -name 'stacker-*' \) -delete
  fi
}

invalidate_stacker_cache target
invalidate_stacker_cache target-quickjs

build_binary() {
  package="$1"
  artifact_name="$2"

  CARGO_TARGET_DIR=target-quickjs RUSTFLAGS="${RUSTFLAGS}" cargo build \
    --locked ${PROFILE_ARGS} -p "${package}" --bin "${package}" \
    --no-default-features --features quickjs

  path="target-quickjs/${RUST_TARGET}/${PROFILE_DIR}/${package}"
  if [ "${BUILD_PROFILE}" = release ]; then
    # The release profile does not emit debug info and asks Cargo to strip
    # symbols. Keep this final artifact-level strip as a defense for custom
    # target/linker behavior; deno compile embeds denort, so any retained
    # symbols would multiply into every generated executable.
    strip --strip-all "${path}"
  fi
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

build_binary deno deno-quickjs-aarch64-unknown-linux-musl
if [ "${BUILD_DENORT}" = 1 ]; then
  build_binary denort denort-quickjs-aarch64-unknown-linux-musl
fi

ccache --show-stats
