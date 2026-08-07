// Copyright 2018-2026 the Deno authors. MIT license.

#[cfg(feature = "v8")]
fn main() {
  // Skip building from docs.rs.
  if std::env::var_os("DOCS_RS").is_some() {
    return;
  }

  deno_runtime::deno_napi::print_linker_flags("denort");
  deno_runtime::deno_webgpu::print_linker_flags("denort");
}

#[cfg(not(feature = "v8"))]
fn main() {}
