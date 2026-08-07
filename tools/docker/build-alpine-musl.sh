#!/bin/sh
set -eu

# Build one native musl engine path. The target directory is selected by the
# engine so V8 and QuickJS caches cannot accidentally satisfy one another.
RUST_TARGET="${RUST_TARGET:-${CARGO_BUILD_TARGET:?CARGO_BUILD_TARGET must be set}}"
ENGINE="${ENGINE:?ENGINE must be set to quickjs or v8}"
ARTIFACT_ARCH="${ARTIFACT_ARCH:?ARTIFACT_ARCH must be set}"
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
  release-quickjs)
    PROFILE_DIR=release-quickjs
    PROFILE_ARGS='--profile release-quickjs'
    ;;
  *)
    echo "ERROR: BUILD_PROFILE must be debug, release, or release-quickjs" >&2
    exit 1
    ;;
esac

case "${ENGINE}" in
  quickjs)
    CARGO_TARGET_SUBDIR=target-quickjs
    QUICKJS_FEATURES=quickjs,musl-mimalloc
    ;;
  v8)
    CARGO_TARGET_SUBDIR=target
    ;;
  *)
    echo "ERROR: ENGINE must be quickjs or v8" >&2
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

patch_stacker() {
  patch_file=/src/deno/tools/docker/stacker-0.1.15-alpine.patch
  stacker_dir="$(find "${CARGO_HOME:-/root/.cargo}/registry/src" -type d -name 'stacker-0.1.15' -print -quit 2>/dev/null || true)"
  if [ -z "${stacker_dir}" ]; then
    echo "ERROR: stacker 0.1.15 source was not downloaded" >&2
    exit 1
  fi
  if ! grep -q 'target_env = "gnu"' "${stacker_dir}/src/lib.rs"; then
    patch -d "${stacker_dir}" -p1 < "${patch_file}"
  fi
}

build_binary() {
  package="$1"
  artifact_name="$2"

  if [ "${ENGINE}" = quickjs ]; then
    CARGO_TARGET_DIR="${CARGO_TARGET_SUBDIR}" RUSTFLAGS="${RUSTFLAGS}" cargo build \
      --locked ${PROFILE_ARGS} -p "${package}" --bin "${package}" \
      --no-default-features --features "${QUICKJS_FEATURES}"
  else
    CARGO_TARGET_DIR="${CARGO_TARGET_SUBDIR}" RUSTFLAGS="${RUSTFLAGS}" cargo build \
      --locked ${PROFILE_ARGS} -p "${package}" --bin "${package}" \
      --features musl-mimalloc
  fi

  path="${CARGO_TARGET_SUBDIR}/${RUST_TARGET}/${PROFILE_DIR}/${package}"
  if [ "${BUILD_PROFILE}" = release ] || [ "${BUILD_PROFILE}" = release-quickjs ]; then
    # Keep the artifact-level strip as a defense for custom target/linker
    # behavior; deno compile embeds denort into every standalone executable.
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

if [ "${ENGINE}" = quickjs ]; then
  quickjs_dependency_tree="$(cargo tree -p deno --no-default-features --features "${QUICKJS_FEATURES}" -e normal)"
  if printf '%s\n' "${quickjs_dependency_tree}" | grep -Eq 'rusty_v8| v8 v150\.4'; then
    echo "ERROR: QuickJS build graph unexpectedly contains the V8 engine" >&2
    exit 1
  fi
fi

patch_stacker

if [ "${ENGINE}" = v8 ]; then
  # Rusty V8 is patched in the image's Cargo registry. A named target volume
  # can otherwise retain a build-script binary from before that source patch.
  CARGO_TARGET_DIR=target cargo clean --target "${RUST_TARGET}" -p v8
fi

build_binary deno "deno-${ENGINE}-${ARTIFACT_ARCH}-unknown-linux-musl"
if [ "${BUILD_DENORT}" = 1 ]; then
  build_binary denort "denort-${ENGINE}-${ARTIFACT_ARCH}-unknown-linux-musl"
fi

ccache --show-stats
