// Copyright 2018-2026 the Deno authors. MIT license.

#[cfg(not(feature = "disable"))]
pub static CLI_SNAPSHOT: Option<&[u8]> = Some(include_bytes!(concat!(
  env!("OUT_DIR"),
  "/CLI_SNAPSHOT.bin"
)));
#[cfg(feature = "disable")]
pub static CLI_SNAPSHOT: Option<&[u8]> = None;

/// `(specifier, source)` pairs for every `lazy_loaded_js` / `lazy_loaded_esm`
/// file that was *not* consumed during snapshot creation. These still need to
/// be available at runtime for `core.loadExtScript()` / the createLazyLoader
/// factory; consumed files live in the snapshot blob itself. The debug
/// `disable` mode omits the V8 blob but keeps this generated residual table so
/// alternate engines can initialize from transpiled extension sources.
mod residual {
  include!(concat!(env!("OUT_DIR"), "/EXTENSION_RESIDUAL_SOURCES.rs"));
}

pub use residual::RESIDUAL_LAZY_ESM;
pub use residual::RESIDUAL_LAZY_JS;

mod shared;

pub use shared::TS_VERSION;
