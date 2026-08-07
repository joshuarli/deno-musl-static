# Native Alpine musl and macOS 26+ QuickJS/V8 build workflows for Deno.
#
# Linux architecture-specific targets select one of four explicit Dockerfiles.
# Cargo target and ccache state live in BuildKit cache mounts so repeated
# iterations do not copy those trees through the Docker build context.
# Exported ELF artifacts are copied into MUSL_ARTIFACT_DIR for inspection and
# smoke testing.

DOCKER ?= docker
DOCKER_BUILD ?= docker buildx build
DOCKER_BUILD_CACHE_ARGS ?=
MUSL_ARCH ?= aarch64
MUSL_ENGINE ?= quickjs
MUSL_PLATFORM ?= linux/arm64
MUSL_IMAGE ?= deno-alpine-$(MUSL_ARCH)-musl-$(MUSL_ENGINE)
MUSL_DOCKERFILE ?= tools/docker/Dockerfile.alpine-$(MUSL_ARCH)-musl-$(MUSL_ENGINE)
MUSL_BUILD_PROFILE ?= debug
MUSL_BUILD_DENORT ?= 1
MUSL_V8_DEBUG ?= true
MUSL_V8_SYMBOL_LEVEL ?= 1
MUSL_RUST_TARGET ?= $(MUSL_ARCH)-alpine-linux-musl

MUSL_ARTIFACT_DIR ?= target/musl-$(MUSL_ARCH)-$(MUSL_ENGINE)-artifacts

MUSL_DENO_ARTIFACT = deno-$(MUSL_ENGINE)-$(MUSL_ARCH)-unknown-linux-musl
MUSL_DENORT_ARTIFACT = denort-$(MUSL_ENGINE)-$(MUSL_ARCH)-unknown-linux-musl

# Native macOS 26+ arm64 builds use separate Cargo target directories per
# engine, so a V8 build cannot satisfy a QuickJS build from an incremental
# cache. They intentionally use macOS's normal allocator and dynamic system
# libraries: neither musl-mimalloc nor static-linking flags belong on this
# path.
MACOS_ARCH ?= aarch64
MACOS_RUST_TARGET ?= $(MACOS_ARCH)-apple-darwin
MACOS_ENGINE ?= quickjs
MACOS_BUILD_PROFILE ?= debug
MACOS_BUILD_DENORT ?= 1
MACOS_TARGET_DIR ?= target/macos-$(MACOS_ARCH)-$(MACOS_ENGINE)
MACOS_ARTIFACT_DIR ?= target/macos-$(MACOS_ARCH)-$(MACOS_ENGINE)-artifacts

MACOS_DENO_ARTIFACT = deno-$(MACOS_ENGINE)-$(MACOS_RUST_TARGET)
MACOS_DENORT_ARTIFACT = denort-$(MACOS_ENGINE)-$(MACOS_RUST_TARGET)

.PHONY: \
	musl-quickjs-debug musl-quickjs-release \
	musl-quickjs-debug-smoke musl-quickjs-release-smoke \
	musl-v8-debug musl-v8-release \
	musl-v8-release-smoke \
	musl-aarch64-quickjs-debug musl-aarch64-quickjs-release \
	musl-aarch64-quickjs-debug-smoke musl-aarch64-quickjs-release-smoke \
	musl-amd64-quickjs-debug musl-amd64-quickjs-release \
	musl-amd64-quickjs-debug-smoke musl-amd64-quickjs-release-smoke \
	musl-aarch64-v8-debug musl-aarch64-v8-release \
	musl-aarch64-v8-release-smoke \
	musl-amd64-v8-debug musl-amd64-v8-release \
	musl-amd64-v8-release-smoke \
	musl-build musl-quickjs-build musl-smoke musl-quickjs-smoke \
	macos-aarch64-quickjs-debug macos-aarch64-quickjs-release \
	macos-aarch64-quickjs-debug-smoke macos-aarch64-quickjs-release-smoke \
	macos-aarch64-v8-debug macos-aarch64-v8-release \
	macos-aarch64-v8-release-smoke \
	macos-build macos-quickjs-build macos-smoke macos-quickjs-smoke

# The original unqualified targets remain arm64 QuickJS compatibility aliases.
# New automation should use the explicit architecture/engine targets below.
musl-quickjs-debug: MUSL_ENGINE=quickjs
musl-quickjs-debug: MUSL_BUILD_PROFILE=debug
musl-quickjs-debug: MUSL_V8_DEBUG=true
musl-quickjs-debug: MUSL_V8_SYMBOL_LEVEL=1
musl-quickjs-debug: musl-build

musl-quickjs-release: MUSL_ENGINE=quickjs
musl-quickjs-release: MUSL_BUILD_PROFILE=release-quickjs
musl-quickjs-release: MUSL_V8_DEBUG=false
musl-quickjs-release: MUSL_V8_SYMBOL_LEVEL=0
musl-quickjs-release: musl-build

musl-quickjs-debug-smoke: MUSL_ENGINE=quickjs
musl-quickjs-debug-smoke: MUSL_BUILD_PROFILE=debug
musl-quickjs-debug-smoke: musl-quickjs-debug musl-smoke

musl-quickjs-release-smoke: MUSL_ENGINE=quickjs
musl-quickjs-release-smoke: MUSL_BUILD_PROFILE=release-quickjs
musl-quickjs-release-smoke: musl-quickjs-release musl-smoke

musl-v8-debug: MUSL_ENGINE=v8
musl-v8-debug: MUSL_BUILD_PROFILE=debug
musl-v8-debug: MUSL_V8_DEBUG=true
musl-v8-debug: MUSL_V8_SYMBOL_LEVEL=1
musl-v8-debug: musl-build

musl-v8-release: MUSL_ENGINE=v8
musl-v8-release: MUSL_BUILD_PROFILE=release
musl-v8-release: MUSL_V8_DEBUG=false
musl-v8-release: MUSL_V8_SYMBOL_LEVEL=0
musl-v8-release: musl-build

musl-v8-release-smoke: MUSL_ENGINE=v8
musl-v8-release-smoke: MUSL_BUILD_PROFILE=release
musl-v8-release-smoke: musl-v8-release musl-smoke

# Explicit architecture targets are the local and CI entry points. Target-
# specific variables are inherited by the engine target and its prerequisites.
musl-aarch64-quickjs-debug musl-aarch64-quickjs-release \
musl-aarch64-quickjs-debug-smoke musl-aarch64-quickjs-release-smoke: \
	MUSL_ARCH=aarch64
musl-aarch64-quickjs-debug musl-aarch64-quickjs-release \
musl-aarch64-quickjs-debug-smoke musl-aarch64-quickjs-release-smoke: \
	MUSL_PLATFORM=linux/arm64
musl-aarch64-quickjs-debug musl-aarch64-quickjs-release \
musl-aarch64-quickjs-debug-smoke musl-aarch64-quickjs-release-smoke: \
	MUSL_RUST_TARGET=aarch64-alpine-linux-musl
musl-aarch64-quickjs-debug musl-aarch64-quickjs-release \
musl-aarch64-quickjs-debug-smoke musl-aarch64-quickjs-release-smoke: \
	MUSL_ENGINE=quickjs
musl-aarch64-quickjs-debug: musl-quickjs-debug
musl-aarch64-quickjs-release: musl-quickjs-release
musl-aarch64-quickjs-debug-smoke: musl-quickjs-debug musl-smoke
musl-aarch64-quickjs-release-smoke: musl-quickjs-release musl-smoke

musl-amd64-quickjs-debug musl-amd64-quickjs-release \
musl-amd64-quickjs-debug-smoke musl-amd64-quickjs-release-smoke: \
	MUSL_ARCH=x86_64
musl-amd64-quickjs-debug musl-amd64-quickjs-release \
musl-amd64-quickjs-debug-smoke musl-amd64-quickjs-release-smoke: \
	MUSL_PLATFORM=linux/amd64
musl-amd64-quickjs-debug musl-amd64-quickjs-release \
musl-amd64-quickjs-debug-smoke musl-amd64-quickjs-release-smoke: \
	MUSL_RUST_TARGET=x86_64-alpine-linux-musl
musl-amd64-quickjs-debug musl-amd64-quickjs-release \
musl-amd64-quickjs-debug-smoke musl-amd64-quickjs-release-smoke: \
	MUSL_ENGINE=quickjs
musl-amd64-quickjs-debug: musl-quickjs-debug
musl-amd64-quickjs-release: musl-quickjs-release
musl-amd64-quickjs-debug-smoke: musl-quickjs-debug musl-smoke
musl-amd64-quickjs-release-smoke: musl-quickjs-release musl-smoke

musl-aarch64-v8-debug musl-aarch64-v8-release \
musl-aarch64-v8-release-smoke: \
	MUSL_ARCH=aarch64
musl-aarch64-v8-debug musl-aarch64-v8-release \
musl-aarch64-v8-release-smoke: \
	MUSL_PLATFORM=linux/arm64
musl-aarch64-v8-debug musl-aarch64-v8-release \
musl-aarch64-v8-release-smoke: \
	MUSL_RUST_TARGET=aarch64-alpine-linux-musl
musl-aarch64-v8-debug musl-aarch64-v8-release \
musl-aarch64-v8-release-smoke: \
	MUSL_ENGINE=v8
musl-aarch64-v8-debug: musl-v8-debug
musl-aarch64-v8-release: musl-v8-release
musl-aarch64-v8-release-smoke: musl-v8-release musl-smoke

musl-amd64-v8-debug musl-amd64-v8-release \
musl-amd64-v8-release-smoke: \
	MUSL_ARCH=x86_64
musl-amd64-v8-debug musl-amd64-v8-release \
musl-amd64-v8-release-smoke: \
	MUSL_PLATFORM=linux/amd64
musl-amd64-v8-debug musl-amd64-v8-release \
musl-amd64-v8-release-smoke: \
	MUSL_RUST_TARGET=x86_64-alpine-linux-musl
musl-amd64-v8-debug musl-amd64-v8-release \
musl-amd64-v8-release-smoke: \
	MUSL_ENGINE=v8
musl-amd64-v8-debug: musl-v8-debug
musl-amd64-v8-release: musl-v8-release
musl-amd64-v8-release-smoke: musl-v8-release musl-smoke

macos-aarch64-quickjs-debug macos-aarch64-quickjs-release \
macos-aarch64-quickjs-debug-smoke macos-aarch64-quickjs-release-smoke: \
	MACOS_ARCH=aarch64
macos-aarch64-quickjs-debug macos-aarch64-quickjs-release \
macos-aarch64-quickjs-debug-smoke macos-aarch64-quickjs-release-smoke: \
	MACOS_RUST_TARGET=aarch64-apple-darwin
macos-aarch64-quickjs-debug macos-aarch64-quickjs-release \
macos-aarch64-quickjs-debug-smoke macos-aarch64-quickjs-release-smoke: \
	MACOS_ENGINE=quickjs
macos-aarch64-quickjs-debug macos-aarch64-quickjs-release \
macos-aarch64-quickjs-debug-smoke macos-aarch64-quickjs-release-smoke: \
	MACOS_TARGET_DIR=target/macos-aarch64-quickjs
macos-aarch64-quickjs-debug macos-aarch64-quickjs-release \
macos-aarch64-quickjs-debug-smoke macos-aarch64-quickjs-release-smoke: \
	MACOS_ARTIFACT_DIR=target/macos-aarch64-quickjs-artifacts
macos-aarch64-quickjs-debug: MACOS_BUILD_PROFILE=debug
macos-aarch64-quickjs-release: MACOS_BUILD_PROFILE=release-quickjs
macos-aarch64-quickjs-debug-smoke: MACOS_BUILD_PROFILE=debug
macos-aarch64-quickjs-release-smoke: MACOS_BUILD_PROFILE=release-quickjs
macos-aarch64-quickjs-debug: macos-build
macos-aarch64-quickjs-release: macos-build
macos-aarch64-quickjs-debug-smoke: macos-aarch64-quickjs-debug macos-smoke
macos-aarch64-quickjs-release-smoke: macos-aarch64-quickjs-release macos-smoke

macos-aarch64-v8-debug macos-aarch64-v8-release \
macos-aarch64-v8-release-smoke: \
	MACOS_ARCH=aarch64
macos-aarch64-v8-debug macos-aarch64-v8-release \
macos-aarch64-v8-release-smoke: \
	MACOS_RUST_TARGET=aarch64-apple-darwin
macos-aarch64-v8-debug macos-aarch64-v8-release \
macos-aarch64-v8-release-smoke: \
	MACOS_ENGINE=v8
macos-aarch64-v8-debug macos-aarch64-v8-release \
macos-aarch64-v8-release-smoke: \
	MACOS_TARGET_DIR=target/macos-aarch64-v8
macos-aarch64-v8-debug macos-aarch64-v8-release \
macos-aarch64-v8-release-smoke: \
	MACOS_ARTIFACT_DIR=target/macos-aarch64-v8-artifacts
macos-aarch64-v8-debug: MACOS_BUILD_PROFILE=debug
macos-aarch64-v8-release: MACOS_BUILD_PROFILE=release
macos-aarch64-v8-release-smoke: MACOS_BUILD_PROFILE=release
macos-aarch64-v8-debug: macos-build
macos-aarch64-v8-release: macos-build
macos-aarch64-v8-release-smoke: macos-aarch64-v8-release macos-smoke

musl-build:
	@set -eu; \
	$(DOCKER_BUILD) $(DOCKER_BUILD_CACHE_ARGS) --load --platform $(MUSL_PLATFORM) \
		--build-arg BUILD_PROFILE=$(MUSL_BUILD_PROFILE) \
		--build-arg BUILD_DENORT=$(MUSL_BUILD_DENORT) \
		--build-arg V8_DEBUG=$(MUSL_V8_DEBUG) \
		--build-arg V8_SYMBOL_LEVEL=$(MUSL_V8_SYMBOL_LEVEL) \
		--build-arg RUST_TARGET=$(MUSL_RUST_TARGET) \
		--tag $(MUSL_IMAGE) \
		--file $(MUSL_DOCKERFILE) .; \
	cid=$$($(DOCKER) create --platform $(MUSL_PLATFORM) $(MUSL_IMAGE)); \
	trap '$(DOCKER) rm -f "$$cid" >/dev/null 2>&1 || true' EXIT; \
	mkdir -p "$(MUSL_ARTIFACT_DIR)"; \
	$(DOCKER) cp "$$cid:/artifacts/." "$(MUSL_ARTIFACT_DIR)/"; \
	$(DOCKER) rm "$$cid" >/dev/null; \
	trap - EXIT

# Backward-compatible implementation names.
musl-quickjs-build: musl-build

# Build the macOS arm64 compiler/runtime pair directly with Cargo. The engine
# is selected at the package boundary; macOS V8 uses the regular V8 backend and
# QuickJS uses the separate release-quickjs profile.
macos-build:
	@set -eu; \
	test "$$(uname -s)" = Darwin || { echo "ERROR: macOS targets require macOS 26 or newer" >&2; exit 1; }; \
	macos_major=$$(sw_vers -productVersion | cut -d. -f1); \
	test "$$macos_major" -ge 26 || { echo "ERROR: macOS targets require macOS 26 or newer" >&2; exit 1; }; \
	profile_dir=debug; \
	profile_args=; \
	case "$(MACOS_ENGINE)" in \
		quickjs|v8) ;; \
		*) echo "ERROR: MACOS_ENGINE must be quickjs or v8" >&2; exit 1 ;; \
	esac; \
	case "$(MACOS_BUILD_PROFILE)" in \
		debug) ;; \
		release) profile_dir=release; profile_args=--release ;; \
		release-quickjs) profile_dir=release-quickjs; profile_args='--profile release-quickjs' ;; \
		*) echo "ERROR: MACOS_BUILD_PROFILE must be debug, release, or release-quickjs" >&2; exit 1 ;; \
	esac; \
	dependency_tree=$$(cargo tree --locked -p deno --no-default-features --features "$(MACOS_ENGINE)" -e normal); \
	if [ "$(MACOS_ENGINE)" = quickjs ] && printf '%s\n' "$$dependency_tree" | grep -Eq 'rusty_v8| v8 v150\\.4'; then \
		echo "ERROR: QuickJS build graph unexpectedly contains the V8 engine" >&2; \
		exit 1; \
	fi; \
	cargo_packages='-p deno'; \
	if [ "$(MACOS_BUILD_DENORT)" = 1 ]; then cargo_packages="$$cargo_packages -p denort"; fi; \
	cargo build --locked --target "$(MACOS_RUST_TARGET)" --target-dir "$(MACOS_TARGET_DIR)" \
		$$profile_args $$cargo_packages --bins \
		--no-default-features --features "$(MACOS_ENGINE)"; \
	copy_binary() { \
		package="$$1"; \
		artifact_name="$$2"; \
		path="$(MACOS_TARGET_DIR)/$(MACOS_RUST_TARGET)/$$profile_dir/$$package"; \
		test -x "$$path"; \
		file "$$path"; \
		mkdir -p "$(MACOS_ARTIFACT_DIR)"; \
		cp "$$path" "$(MACOS_ARTIFACT_DIR)/$$artifact_name"; \
		chmod +x "$(MACOS_ARTIFACT_DIR)/$$artifact_name"; \
	}; \
	copy_binary deno "$(MACOS_DENO_ARTIFACT)"; \
	if [ "$(MACOS_BUILD_DENORT)" = 1 ]; then \
		copy_binary denort "$(MACOS_DENORT_ARTIFACT)"; \
	fi

macos-quickjs-build: MACOS_ENGINE=quickjs
macos-quickjs-build: macos-build

# Run the macOS pair and compile a standalone program with its selected engine.
macos-smoke:
	@test -x "$(MACOS_ARTIFACT_DIR)/$(MACOS_DENO_ARTIFACT)" || { echo "missing $(MACOS_ARTIFACT_DIR)/$(MACOS_DENO_ARTIFACT); run a macOS build target first" >&2; exit 1; }
	@test -x "$(MACOS_ARTIFACT_DIR)/$(MACOS_DENORT_ARTIFACT)" || { echo "missing $(MACOS_ARTIFACT_DIR)/$(MACOS_DENORT_ARTIFACT); set MACOS_BUILD_DENORT=1 and run a macOS build target first" >&2; exit 1; }
	@set -eu; \
	deno="$(MACOS_ARTIFACT_DIR)/$(MACOS_DENO_ARTIFACT)"; \
	denort="$(MACOS_ARTIFACT_DIR)/$(MACOS_DENORT_ARTIFACT)"; \
	"$$deno" --version; \
	printf 'console.log(42)\n' >/tmp/deno-quickjs-macos-smoke.ts; \
	if [ "$(MACOS_ENGINE)" = quickjs ]; then \
		DENORT_BIN="$$denort" "$$deno" compile --engine quickjs --output /tmp/deno-quickjs-macos-smoke /tmp/deno-quickjs-macos-smoke.ts; \
	else \
		"$$deno" eval "console.log(42)"; \
		DENORT_BIN="$$denort" "$$deno" compile --output /tmp/deno-v8-macos-smoke /tmp/deno-quickjs-macos-smoke.ts; \
	fi; \
	if [ "$(MACOS_ENGINE)" = quickjs ]; then /tmp/deno-quickjs-macos-smoke; else /tmp/deno-v8-macos-smoke; fi

# Run the generated compiler/runtime pair and a compiled standalone program in
# native Alpine. The V8 smoke also runs direct JavaScript through V8; the
# QuickJS smoke selects its engine explicitly.
musl-smoke:
	@test -x "$(MUSL_ARTIFACT_DIR)/$(MUSL_DENO_ARTIFACT)" || { echo "missing $(MUSL_ARTIFACT_DIR)/$(MUSL_DENO_ARTIFACT); run a build target first" >&2; exit 1; }
	@test -x "$(MUSL_ARTIFACT_DIR)/$(MUSL_DENORT_ARTIFACT)" || { echo "missing $(MUSL_ARTIFACT_DIR)/$(MUSL_DENORT_ARTIFACT); set MUSL_BUILD_DENORT=1 and run a build target first" >&2; exit 1; }
	@$(DOCKER) run --rm --platform $(MUSL_PLATFORM) \
		-v "$(abspath $(MUSL_ARTIFACT_DIR)):/artifacts:ro" \
		alpine:latest sh -ec '\
			apk add --no-cache binutils file >/dev/null; \
			deno=/artifacts/$(MUSL_DENO_ARTIFACT); \
			denort=/artifacts/$(MUSL_DENORT_ARTIFACT); \
			test -z "$$(readelf -lW "$$deno" | grep INTERP || true)"; \
			test -z "$$(readelf -dW "$$deno" | grep NEEDED || true)"; \
			test -z "$$(readelf -lW "$$denort" | grep INTERP || true)"; \
			test -z "$$(readelf -dW "$$denort" | grep NEEDED || true)"; \
			"$$deno" --version; \
			printf "console.log(42)\\n" >/tmp/hello.ts; \
			if [ "$(MUSL_ENGINE)" = quickjs ]; then \
				DENORT_BIN="$$denort" "$$deno" compile --engine quickjs --output /tmp/hello /tmp/hello.ts; \
			else \
				"$$deno" eval "console.log(42)"; \
				DENORT_BIN="$$denort" "$$deno" compile --output /tmp/hello /tmp/hello.ts; \
			fi; \
			/tmp/hello; \
			file /tmp/hello; \
			test -z "$$(readelf -lW /tmp/hello | grep INTERP || true)"; \
			test -z "$$(readelf -dW /tmp/hello | grep NEEDED || true)"'

musl-quickjs-smoke: MUSL_ENGINE=quickjs
musl-quickjs-smoke: musl-smoke
