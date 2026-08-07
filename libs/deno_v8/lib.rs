// Copyright 2018-2026 the Deno authors. MIT license.

#[cfg(all(feature = "v8", feature = "quickjs"))]
compile_error!("features `v8` and `quickjs` are mutually exclusive");

#[cfg(not(any(feature = "v8", feature = "quickjs")))]
compile_error!("either feature `v8` or `quickjs` must be enabled");

#[cfg(all(feature = "v8", not(feature = "quickjs")))]
pub use rusty_v8::*;
#[cfg(all(feature = "quickjs", not(feature = "v8")))]
pub use v8x_backend::*;

/// Name and version of the engine actually linked into this facade. The
/// QuickJS backend intentionally keeps `VERSION_STRING` equal to its V8 ABI
/// compatibility version, so callers displaying the runtime engine must use
/// these backend-specific values instead.
#[cfg(feature = "v8")]
pub const ENGINE_NAME: &str = "v8";
#[cfg(feature = "v8")]
pub const ENGINE_VERSION_STRING: &str = VERSION_STRING;

#[cfg(feature = "quickjs")]
pub const ENGINE_NAME: &str = "quickjs";
// Keep this in sync with the QuickJS-ng version vendored by the pinned `v8x`
// backend dependency.
#[cfg(feature = "quickjs")]
pub const ENGINE_VERSION_STRING: &str = "0.15.1";
