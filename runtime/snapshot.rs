// Copyright 2018-2026 the Deno authors. MIT license.

use std::io::Write;
use std::path::PathBuf;
use std::rc::Rc;

use deno_core::Extension;
use deno_core::snapshot::*;
use deno_core::v8;

use crate::ops::bootstrap::SnapshotOptions;

pub use crate::snapshot_files::LazyExtensionFile;
pub use crate::snapshot_files::LazyExtensionFileKind;

pub struct CreateRuntimeSnapshotOutput {
  /// Paths the snapshot read from disk; emit as `cargo:rerun-if-changed`.
  pub files_loaded_during_snapshot: Vec<PathBuf>,
  /// Specifiers of `lazy_loaded_*` files compiled into the snapshot blob.
  /// Their source already lives in the snapshot; no `include_str!` is needed.
  pub consumed_lazy_specifiers: Vec<String>,
  /// Every `lazy_loaded_*` file declared by any extension fed to the snapshot.
  /// The residual set the binary needs at runtime is
  /// `lazy_extension_files \ consumed_lazy_specifiers`.
  pub lazy_extension_files: Vec<LazyExtensionFile>,
}

pub fn create_runtime_snapshot(
  snapshot_path: PathBuf,
  snapshot_options: SnapshotOptions,
  // NOTE: For embedders that wish to add additional extensions to the snapshot
  custom_extensions: Vec<Extension>,
) -> CreateRuntimeSnapshotOutput {
  // Keep this extension ordering centralized with the debug residual-source
  // collector so the two paths cannot silently diverge.
  let mut extensions =
    crate::snapshot_files::runtime_extensions(Some(snapshot_options));
  extensions.extend(custom_extensions);

  let lazy_extension_files =
    crate::snapshot_files::collect_lazy_extension_files(&extensions);
  let minify_sources =
    std::env::var_os("DENO_SNAPSHOT_MINIFY_SOURCES").is_some();

  let output = create_snapshot(
    CreateSnapshotOptions {
      cargo_manifest_dir: env!("CARGO_MANIFEST_DIR"),
      startup_snapshot: None,
      extensions,
      extension_transpiler: Some(Rc::new(move |specifier, source| {
        if minify_sources {
          crate::transpile::maybe_transpile_and_minify_source(specifier, source)
        } else {
          crate::transpile::maybe_transpile_source(specifier, source)
        }
      })),
      with_runtime_cb: Some(Box::new(|rt| {
        let isolate = rt.v8_isolate();
        v8::scope!(scope, isolate);

        let tmpl = deno_node::init_global_template(
          scope,
          deno_node::ContextInitMode::ForSnapshot,
        );
        let ctx = deno_node::create_v8_context(
          scope,
          tmpl,
          deno_node::ContextInitMode::ForSnapshot,
          std::ptr::null_mut(),
        );
        assert_eq!(scope.add_context(ctx), deno_node::VM_CONTEXT_INDEX);
      })),
      skip_op_registration: false,
    },
    None,
  )
  .unwrap();
  let mut snapshot = std::fs::File::create(snapshot_path).unwrap();
  snapshot.write_all(&output.output).unwrap();

  #[allow(clippy::print_stdout, reason = "necessary for build code")]
  for path in &output.files_loaded_during_snapshot {
    println!("cargo:rerun-if-changed={}", path.display());
  }

  CreateRuntimeSnapshotOutput {
    files_loaded_during_snapshot: output.files_loaded_during_snapshot,
    consumed_lazy_specifiers: output.consumed_lazy_specifiers,
    lazy_extension_files,
  }
}
