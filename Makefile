# Static aarch64 musl QuickJS build workflows.
#
# The Docker image builds natively on linux/arm64. Cargo target and ccache
# state live in named volumes so repeated debug/release iterations do not copy
# those trees through the Docker build context. Exported ELF artifacts are
# copied into MUSL_ARTIFACT_DIR for inspection and smoke testing.

DOCKER ?= docker
MUSL_PLATFORM ?= linux/arm64
MUSL_IMAGE ?= deno-alpine-aarch64-musl
MUSL_BUILD_PROFILE ?= debug
MUSL_BUILD_DENORT ?= 1
MUSL_V8_DEBUG ?= true
MUSL_V8_SYMBOL_LEVEL ?= 1
MUSL_RUST_TARGET ?= aarch64-alpine-linux-musl

MUSL_TARGET_VOLUME ?= deno-aarch64-musl-target
MUSL_QUICKJS_TARGET_VOLUME ?= deno-aarch64-musl-quickjs-target
MUSL_CCACHE_VOLUME ?= deno-aarch64-musl-ccache
MUSL_ARTIFACT_VOLUME ?= deno-aarch64-musl-artifacts
MUSL_ARTIFACT_DIR ?= target/musl-aarch64-artifacts

MUSL_DENO_ARTIFACT := deno-quickjs-aarch64-unknown-linux-musl
MUSL_DENORT_ARTIFACT := denort-quickjs-aarch64-unknown-linux-musl

.PHONY: musl-quickjs-debug musl-quickjs-release \
	musl-quickjs-debug-smoke musl-quickjs-release-smoke \
	musl-quickjs-build musl-quickjs-smoke

# Debug keeps symbols and uses the ordinary debug Cargo profile.
musl-quickjs-debug: MUSL_BUILD_PROFILE=debug
musl-quickjs-debug: MUSL_V8_DEBUG=true
musl-quickjs-debug: MUSL_V8_SYMBOL_LEVEL=1
musl-quickjs-debug: musl-quickjs-build

# Release QuickJS uses ThinLTO, opt-level 3, and no debug/symbol sections.
musl-quickjs-release: MUSL_BUILD_PROFILE=release-quickjs
musl-quickjs-release: MUSL_V8_DEBUG=false
musl-quickjs-release: MUSL_V8_SYMBOL_LEVEL=0
musl-quickjs-release: musl-quickjs-build

musl-quickjs-debug-smoke: MUSL_BUILD_PROFILE=debug
musl-quickjs-debug-smoke: musl-quickjs-debug musl-quickjs-smoke

musl-quickjs-release-smoke: MUSL_BUILD_PROFILE=release-quickjs
musl-quickjs-release-smoke: musl-quickjs-release musl-quickjs-smoke

musl-quickjs-build:
	@set -eu; \
	$(DOCKER) build --platform $(MUSL_PLATFORM) \
		--build-arg BUILD_PROFILE=$(MUSL_BUILD_PROFILE) \
		--build-arg BUILD_DENORT=$(MUSL_BUILD_DENORT) \
		--build-arg V8_DEBUG=$(MUSL_V8_DEBUG) \
		--build-arg V8_SYMBOL_LEVEL=$(MUSL_V8_SYMBOL_LEVEL) \
		--build-arg RUST_TARGET=$(MUSL_RUST_TARGET) \
		--tag $(MUSL_IMAGE) \
		--file tools/docker/Dockerfile.alpine-aarch64-musl .; \
	$(DOCKER) volume create $(MUSL_TARGET_VOLUME) >/dev/null; \
	$(DOCKER) volume create $(MUSL_QUICKJS_TARGET_VOLUME) >/dev/null; \
	$(DOCKER) volume create $(MUSL_CCACHE_VOLUME) >/dev/null; \
	$(DOCKER) volume create $(MUSL_ARTIFACT_VOLUME) >/dev/null; \
	cid=$$($(DOCKER) create --platform $(MUSL_PLATFORM) \
		--mount type=volume,source=$(MUSL_TARGET_VOLUME),target=/src/deno/target \
		--mount type=volume,source=$(MUSL_QUICKJS_TARGET_VOLUME),target=/src/deno/target-quickjs \
		--mount type=volume,source=$(MUSL_CCACHE_VOLUME),target=/ccache \
		--mount type=volume,source=$(MUSL_ARTIFACT_VOLUME),target=/artifacts \
		$(MUSL_IMAGE)); \
	trap '$(DOCKER) rm -f "$$cid" >/dev/null 2>&1 || true' EXIT; \
	$(DOCKER) start -a "$$cid"; \
	mkdir -p "$(MUSL_ARTIFACT_DIR)"; \
	$(DOCKER) cp "$$cid:/artifacts/." "$(MUSL_ARTIFACT_DIR)/"; \
	$(DOCKER) rm "$$cid" >/dev/null; \
	trap - EXIT

# Run the generated QuickJS compiler/runtime pair and a compiled standalone
# program in native Alpine arm64. This target intentionally does not validate
# the V8 or desktop paths.
musl-quickjs-smoke:
	@test -x "$(MUSL_ARTIFACT_DIR)/$(MUSL_DENO_ARTIFACT)" || { echo "missing $(MUSL_ARTIFACT_DIR)/$(MUSL_DENO_ARTIFACT); run a build target first" >&2; exit 1; }
	@test -x "$(MUSL_ARTIFACT_DIR)/$(MUSL_DENORT_ARTIFACT)" || { echo "missing $(MUSL_ARTIFACT_DIR)/$(MUSL_DENORT_ARTIFACT); set MUSL_BUILD_DENORT=1 and run a build target first" >&2; exit 1; }
	@$(DOCKER) run --rm --platform $(MUSL_PLATFORM) \
		-v "$(abspath $(MUSL_ARTIFACT_DIR)):/artifacts:ro" \
		alpine:latest sh -ec '\
			apk add --no-cache binutils file >/dev/null; \
			deno=/artifacts/$(MUSL_DENO_ARTIFACT); \
			denort=/artifacts/$(MUSL_DENORT_ARTIFACT); \
			test -z "$$(readelf -lW "$$deno" | awk "/INTERP/{print}"); \
			test -z "$$(readelf -dW "$$deno" | awk "/NEEDED/{print}"); \
			test -z "$$(readelf -lW "$$denort" | awk "/INTERP/{print}"); \
			test -z "$$(readelf -dW "$$denort" | awk "/NEEDED/{print}"); \
			"$$deno" --version; \
			printf "console.log(42)\\n" >/tmp/hello.ts; \
			DENORT_BIN="$$denort" "$$deno" compile --engine quickjs --output /tmp/hello /tmp/hello.ts; \
			/tmp/hello; \
			file /tmp/hello; \
			test -z "$$(readelf -lW /tmp/hello | awk "/INTERP/{print}"); \
			test -z "$$(readelf -dW /tmp/hello | awk "/NEEDED/{print}")'
