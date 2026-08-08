// Copyright 2018-2026 the Deno authors. MIT license.

use std::borrow::Cow;
use std::collections::HashSet;
use std::ffi::OsString;
use std::path::Path;
use std::path::PathBuf;
use std::str::FromStr;

pub use deno_cli_parser::flags::*;
use deno_config::glob::FilePatterns;
use deno_config::glob::PathOrPatternSet;
use deno_core::anyhow::Context;
use deno_core::error::AnyError;
use deno_graph::GraphKind;
use deno_npm::NpmSystemInfo;
use deno_path_util::normalize_path;
use deno_path_util::resolve_url_or_path;
use deno_path_util::url_to_file_path;
use deno_runtime::deno_telemetry::OtelConfig;
use deno_runtime::deno_telemetry::OtelConsoleConfig;
use deno_runtime::deno_telemetry::OtelPropagators;

use crate::util::env::resolve_cwd;
use crate::util::fs::canonicalize_path;

pub static UPGRADE_USAGE: &str = "deno upgrade [VERSION|CHANNEL]";

fn normalize_args(args: Vec<OsString>) -> Vec<String> {
  let mut args = args
    .into_iter()
    .map(|arg| arg.to_string_lossy().into_owned())
    .collect::<Vec<_>>();

  // Keep the existing dx/denox/dnx shim behavior without constructing a
  // command parser.
  if args.first().is_some_and(|arg| {
    arg.ends_with("dx") || arg.ends_with("denox") || arg.ends_with("dnx")
  }) {
    args.insert(1, "x".to_string());
  }

  args
}

/// Parse command-line arguments into the canonical CLI flags.
///
/// The parser is intentionally static: command definitions live in
/// deno_cli_parser, while this module retains CLI-only flag helper traits.
pub fn flags_from_vec(
  args: Vec<OsString>,
) -> Result<Flags, deno_cli_parser::CliError> {
  deno_cli_parser::convert::flags_from_vec(normalize_args(args))
}

pub fn flags_from_vec_with_initial_cwd(
  args: Vec<OsString>,
  initial_cwd: Option<PathBuf>,
) -> Result<Flags, deno_cli_parser::CliError> {
  let mut flags = flags_from_vec(args)?;
  flags.initial_cwd = initial_cwd;
  Ok(flags)
}

/// Shell completion is intentionally disabled with the static parser.
///
/// COMPLETE is still recognized by the caller so completion probes exit
/// before initializing the runtime.
pub fn handle_shell_completion(_cwd: &Path) -> Result<(), AnyError> {
  Ok(())
}
fn join_paths(allowlist: &[String], d: &str) -> String {
  allowlist
    .iter()
    .map(|path| path.to_string())
    .collect::<Vec<String>>()
    .join(d)
}

pub trait FileFlagsExt {
  fn as_file_patterns(&self, base: &Path) -> Result<FilePatterns, AnyError>;
}

impl FileFlagsExt for FileFlags {
  fn as_file_patterns(&self, base: &Path) -> Result<FilePatterns, AnyError> {
    Ok(FilePatterns {
      include: if self.include.is_empty() {
        None
      } else {
        Some(PathOrPatternSet::from_include_relative_path_or_patterns(
          base,
          &self.include,
        )?)
      },
      exclude: PathOrPatternSet::from_exclude_relative_path_or_patterns(
        base,
        &self.ignore,
      )?,
      base: base.to_path_buf(),
    })
  }
}

pub trait CompileFlagsExt {
  fn resolve_target(&self) -> String;
}

impl CompileFlagsExt for CompileFlags {
  fn resolve_target(&self) -> String {
    self
      .target
      .clone()
      .unwrap_or_else(|| env!("TARGET").to_string())
  }
}

fn npm_system_info_from_env() -> NpmSystemInfo {
  let arch = std::env::var_os("DENO_INSTALL_ARCH");
  if let Some(var) = arch.as_ref().and_then(|s| s.to_str()) {
    NpmSystemInfo::from_rust(std::env::consts::OS, var)
  } else {
    NpmSystemInfo::default()
  }
}

pub trait DenoSubcommandExt {
  fn npm_system_info(&self) -> NpmSystemInfo;
}

impl DenoSubcommandExt for DenoSubcommand {
  fn npm_system_info(&self) -> NpmSystemInfo {
    match self {
      DenoSubcommand::Compile(CompileFlags {
        target: Some(target),
        ..
      })
      | DenoSubcommand::Desktop(DesktopFlags {
        target: Some(target),
        ..
      }) => {
        // the values of NpmSystemInfo align with the possible values for the
        // `arch` and `platform` fields of Node.js' `process` global:
        // https://nodejs.org/api/process.html
        match target.as_str() {
          "aarch64-apple-darwin" => NpmSystemInfo {
            os: "darwin".into(),
            cpu: "arm64".into(),
          },
          "aarch64-unknown-linux-gnu" => NpmSystemInfo {
            os: "linux".into(),
            cpu: "arm64".into(),
          },
          "aarch64-unknown-linux-musl" => NpmSystemInfo {
            os: "linux".into(),
            cpu: "arm64".into(),
          },
          "x86_64-apple-darwin" => NpmSystemInfo {
            os: "darwin".into(),
            cpu: "x64".into(),
          },
          "x86_64-unknown-linux-gnu" => NpmSystemInfo {
            os: "linux".into(),
            cpu: "x64".into(),
          },
          "x86_64-pc-windows-msvc" => NpmSystemInfo {
            os: "win32".into(),
            cpu: "x64".into(),
          },
          value => {
            log::warn!(
              concat!(
                "Not implemented npm system info for target '{}'. Using current ",
                "system default. This may impact architecture specific dependencies."
              ),
              value,
            );
            NpmSystemInfo::default()
          }
        }
      }
      DenoSubcommand::Install(InstallFlags::Local(
        _,
        NpmInstallTargetFlags { os, arch },
      )) => {
        let default = npm_system_info_from_env();
        NpmSystemInfo {
          os: os.as_deref().unwrap_or(&default.os).into(),
          cpu: arch.as_deref().unwrap_or(&default.cpu).into(),
        }
      }
      _ => npm_system_info_from_env(),
    }
  }
}

pub trait TypeCheckModeExt {
  fn as_graph_kind(&self) -> GraphKind;
}

impl TypeCheckModeExt for TypeCheckMode {
  /// Gets the corresponding module `GraphKind` that should be created
  /// for the current `TypeCheckMode`.
  fn as_graph_kind(&self) -> GraphKind {
    match self.is_true() {
      true => GraphKind::All,
      false => GraphKind::CodeOnly,
    }
  }
}

pub trait FlagsExt {
  fn to_permission_args(&self) -> Vec<String>;
  fn no_legacy_abort(&self) -> bool;
  fn otel_config(&self) -> OtelConfig;
  fn config_path_args(&self, current_dir: &Path) -> Option<Vec<PathBuf>>;
  fn allow_all(&mut self);
  fn resolve_watch_exclude_set(&self) -> Result<PathOrPatternSet, AnyError>;
}

impl FlagsExt for Flags {
  /// Return list of permission arguments that are equivalent
  /// to the ones used to create `self`.
  fn to_permission_args(&self) -> Vec<String> {
    let mut args = vec![];

    if self.permissions.allow_all {
      args.push("--allow-all".to_string());
      return args;
    }

    match &self.permissions.allow_read {
      Some(read_allowlist) if read_allowlist.is_empty() => {
        args.push("--allow-read".to_string());
      }
      Some(read_allowlist) => {
        let s = format!("--allow-read={}", join_paths(read_allowlist, ","));
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.deny_read {
      Some(read_denylist) if read_denylist.is_empty() => {
        args.push("--deny-read".to_string());
      }
      Some(read_denylist) => {
        let s = format!("--deny-read={}", join_paths(read_denylist, ","));
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.allow_write {
      Some(write_allowlist) if write_allowlist.is_empty() => {
        args.push("--allow-write".to_string());
      }
      Some(write_allowlist) => {
        let s = format!("--allow-write={}", join_paths(write_allowlist, ","));
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.deny_write {
      Some(write_denylist) if write_denylist.is_empty() => {
        args.push("--deny-write".to_string());
      }
      Some(write_denylist) => {
        let s = format!("--deny-write={}", join_paths(write_denylist, ","));
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.allow_net {
      Some(net_allowlist) if net_allowlist.is_empty() => {
        args.push("--allow-net".to_string());
      }
      Some(net_allowlist) => {
        let s = format!("--allow-net={}", net_allowlist.join(","));
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.deny_net {
      Some(net_denylist) if net_denylist.is_empty() => {
        args.push("--deny-net".to_string());
      }
      Some(net_denylist) => {
        let s = format!("--deny-net={}", net_denylist.join(","));
        args.push(s);
      }
      _ => {}
    }

    match &self.unsafely_ignore_certificate_errors {
      Some(ic_allowlist) if ic_allowlist.is_empty() => {
        args.push("--unsafely-ignore-certificate-errors".to_string());
      }
      Some(ic_allowlist) => {
        let s = format!(
          "--unsafely-ignore-certificate-errors={}",
          ic_allowlist.join(",")
        );
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.allow_env {
      Some(env_allowlist) if env_allowlist.is_empty() => {
        args.push("--allow-env".to_string());
      }
      Some(env_allowlist) => {
        let s = format!("--allow-env={}", env_allowlist.join(","));
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.deny_env {
      Some(env_denylist) if env_denylist.is_empty() => {
        args.push("--deny-env".to_string());
      }
      Some(env_denylist) => {
        let s = format!("--deny-env={}", env_denylist.join(","));
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.ignore_env {
      Some(ignorelist) if ignorelist.is_empty() => {
        args.push("--ignore-env".to_string());
      }
      Some(ignorelist) => {
        let s = format!("--ignore-env={}", ignorelist.join(","));
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.ignore_read {
      Some(ignorelist) if ignorelist.is_empty() => {
        args.push("--ignore-read".to_string());
      }
      Some(ignorelist) => {
        let s = format!("--ignore-read={}", ignorelist.join(","));
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.allow_run {
      Some(run_allowlist) if run_allowlist.is_empty() => {
        args.push("--allow-run".to_string());
      }
      Some(run_allowlist) => {
        let s = format!("--allow-run={}", run_allowlist.join(","));
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.deny_run {
      Some(run_denylist) if run_denylist.is_empty() => {
        args.push("--deny-run".to_string());
      }
      Some(run_denylist) => {
        let s = format!("--deny-run={}", run_denylist.join(","));
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.allow_sys {
      Some(sys_allowlist) if sys_allowlist.is_empty() => {
        args.push("--allow-sys".to_string());
      }
      Some(sys_allowlist) => {
        let s = format!("--allow-sys={}", sys_allowlist.join(","));
        args.push(s)
      }
      _ => {}
    }

    match &self.permissions.deny_sys {
      Some(sys_denylist) if sys_denylist.is_empty() => {
        args.push("--deny-sys".to_string());
      }
      Some(sys_denylist) => {
        let s = format!("--deny-sys={}", sys_denylist.join(","));
        args.push(s)
      }
      _ => {}
    }

    match &self.permissions.allow_ffi {
      Some(ffi_allowlist) if ffi_allowlist.is_empty() => {
        args.push("--allow-ffi".to_string());
      }
      Some(ffi_allowlist) => {
        let s = format!("--allow-ffi={}", join_paths(ffi_allowlist, ","));
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.deny_ffi {
      Some(ffi_denylist) if ffi_denylist.is_empty() => {
        args.push("--deny-ffi".to_string());
      }
      Some(ffi_denylist) => {
        let s = format!("--deny-ffi={}", join_paths(ffi_denylist, ","));
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.allow_import {
      Some(allowlist) if allowlist.is_empty() => {
        args.push("--allow-import".to_string());
      }
      Some(allowlist) => {
        let s = format!("--allow-import={}", allowlist.join(","));
        args.push(s);
      }
      _ => {}
    }

    match &self.permissions.deny_import {
      Some(denylist) if denylist.is_empty() => {
        args.push("--deny-import".to_string());
      }
      Some(denylist) => {
        let s = format!("--deny-import={}", denylist.join(","));
        args.push(s);
      }
      _ => {}
    }

    args
  }

  fn no_legacy_abort(&self) -> bool {
    self
      .unstable_config
      .features
      .contains(&String::from("no-legacy-abort"))
  }

  fn otel_config(&self) -> OtelConfig {
    let otel_var = |name| match std::env::var(name) {
      Ok(s) if s.eq_ignore_ascii_case("true") => Some(true),
      Ok(s) if s.eq_ignore_ascii_case("false") => Some(false),
      Ok(_) => {
        log::warn!(
          "'{name}' env var value not recognized, only 'true' and 'false' are accepted"
        );
        None
      }
      Err(_) => None,
    };

    let disabled = otel_var("OTEL_SDK_DISABLED").unwrap_or(false);
    let default = !disabled && otel_var("OTEL_DENO").unwrap_or(false);

    let propagators = if default {
      if let Ok(propagators) = std::env::var("OTEL_PROPAGATORS") {
        propagators
          .split(',')
          .filter_map(|p| match p.trim() {
            "tracecontext" => Some(OtelPropagators::TraceContext),
            "baggage" => Some(OtelPropagators::Baggage),
            _ => None,
          })
          .collect()
      } else {
        HashSet::from([OtelPropagators::TraceContext, OtelPropagators::Baggage])
      }
    } else {
      HashSet::default()
    };

    OtelConfig {
      tracing_enabled: !disabled
        && otel_var("OTEL_DENO_TRACING").unwrap_or(default),
      metrics_enabled: !disabled
        && otel_var("OTEL_DENO_METRICS").unwrap_or(default),
      propagators,
      console: match std::env::var("OTEL_DENO_CONSOLE").as_deref() {
        Ok(_) if disabled => OtelConsoleConfig::Ignore,
        Ok("ignore") => OtelConsoleConfig::Ignore,
        Ok("capture") => OtelConsoleConfig::Capture,
        Ok("replace") => OtelConsoleConfig::Replace,
        res => {
          if res.is_ok() {
            log::warn!("'OTEL_DENO_CONSOLE' env var value not recognized, only 'ignore', 'capture', or 'replace' are accepted");
          }
          if default {
            OtelConsoleConfig::Capture
          } else {
            OtelConsoleConfig::Ignore
          }
        }
      },
      deterministic_prefix: std::env::var("DENO_UNSTABLE_OTEL_DETERMINISTIC")
        .as_deref()
        .map(u8::from_str)
        .map(|x| match x {
          Ok(x) => Some(x),
          Err(_) => {
            log::warn!("'DENO_UNSTABLE_OTEL_DETERMINISTIC' env var value not recognized, only integers are accepted");
            None
          }
        })
        .ok()
        .flatten(),
    }
  }

  /// Extract the paths the config file should be discovered from.
  ///
  /// Returns `None` if the config file should not be auto-discovered.
  fn config_path_args(&self, current_dir: &Path) -> Option<Vec<PathBuf>> {
    fn resolve_multiple_files(
      files_or_dirs: &[String],
      current_dir: &Path,
    ) -> Vec<PathBuf> {
      let mut seen = HashSet::with_capacity(files_or_dirs.len());
      let result = files_or_dirs
        .iter()
        .filter_map(|p| {
          let path = normalize_path(Cow::Owned(current_dir.join(p)));
          if seen.insert(path.clone()) {
            Some(path.into_owned())
          } else {
            None
          }
        })
        .collect::<Vec<_>>();
      if result.is_empty() {
        vec![current_dir.to_path_buf()]
      } else {
        result
      }
    }

    fn resolve_single_folder_path(
      arg: &str,
      current_dir: &Path,
      maybe_resolve_directory: impl FnOnce(PathBuf) -> Option<PathBuf>,
    ) -> Option<PathBuf> {
      if let Ok(module_specifier) = resolve_url_or_path(arg, current_dir) {
        if module_specifier.scheme() == "file"
          || module_specifier.scheme() == "npm"
          || module_specifier.scheme() == "jsr"
        {
          if let Ok(p) = url_to_file_path(&module_specifier) {
            maybe_resolve_directory(p)
          } else {
            Some(current_dir.to_path_buf())
          }
        } else {
          // When the entrypoint is a remote script (e.g. https:), then we
          // don't auto discover the config file. Package entrypoints (npm:,
          // jsr:) resolve within the project context, so they do.
          None
        }
      } else {
        Some(current_dir.to_path_buf())
      }
    }

    use DenoSubcommand::*;
    match &self.subcommand {
      Fmt(FmtFlags { files, .. }) => {
        Some(resolve_multiple_files(&files.include, current_dir))
      }
      Lint(LintFlags { files, .. }) => {
        Some(resolve_multiple_files(&files.include, current_dir))
      }
      Run(RunFlags { script, .. })
      | Compile(CompileFlags {
        source_file: script,
        ..
      }) => resolve_single_folder_path(script, current_dir, |mut p| {
        if p.pop() { Some(p) } else { None }
      })
      .map(|p| vec![p]),
      Desktop(DesktopFlags {
        source_file: script,
        ..
      }) => resolve_single_folder_path(script, current_dir, |p| {
        // The desktop entrypoint is commonly a directory (e.g. `deno desktop
        // .` for framework detection), in which case the config lives in that
        // directory itself — don't pop up to its parent. Only pop when the
        // entrypoint is a file.
        if p.is_dir() {
          Some(p)
        } else {
          p.parent().map(|parent| parent.to_path_buf())
        }
      })
      .map(|p| vec![p]),
      Task(TaskFlags {
        cwd: Some(path), ..
      }) => {
        // todo(dsherret): Why is this canonicalized? Document why.
        // attempt to resolve the config file from the task subcommand's
        // `--cwd` when specified
        match canonicalize_path(Path::new(path)) {
          Ok(path) => Some(vec![path]),
          Err(_) => Some(vec![current_dir.to_path_buf()]),
        }
      }
      Cache(CacheFlags { files, .. })
      | Install(InstallFlags::Local(
        InstallFlagsLocal::Entrypoints(InstallEntrypointsFlags {
          entrypoints: files,
          ..
        }),
        _,
      )) => Some(vec![
        files
          .iter()
          .filter_map(|file| {
            resolve_single_folder_path(file, current_dir, |mut p| {
              if p.is_dir() {
                return Some(p);
              }
              if p.pop() { Some(p) } else { None }
            })
          })
          .next()
          .unwrap_or_else(|| current_dir.to_path_buf()),
      ]),
      _ => Some(vec![current_dir.to_path_buf()]),
    }
  }

  #[inline(always)]
  fn allow_all(&mut self) {
    self.permissions.allow_all = true;
    self.permissions.allow_read = None;
    self.permissions.allow_env = None;
    self.permissions.allow_net = None;
    self.permissions.allow_run = None;
    self.permissions.allow_write = None;
    self.permissions.allow_sys = None;
    self.permissions.allow_ffi = None;
    self.permissions.allow_import = None;
  }

  fn resolve_watch_exclude_set(&self) -> Result<PathOrPatternSet, AnyError> {
    match &self.watch {
      Some(WatchFlagsWithPaths {
        exclude: excluded_paths,
        ..
      }) => {
        let cwd = resolve_cwd(self.initial_cwd.as_deref())?;
        PathOrPatternSet::from_exclude_relative_path_or_patterns(
          &cwd,
          excluded_paths,
        )
        .context("Failed resolving watch exclude patterns.")
      }
      _ => Ok(PathOrPatternSet::default()),
    }
  }
}
