use std::borrow::Cow;
use std::collections::HashSet;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct OtelRuntimeConfig {
  pub runtime_name: Cow<'static, str>,
  pub runtime_version: Cow<'static, str>,
}

#[derive(Default, Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct OtelConfig {
  pub tracing_enabled: bool,
  pub metrics_enabled: bool,
  pub console: OtelConsoleConfig,
  pub deterministic_prefix: Option<u8>,
  pub propagators: HashSet<OtelPropagators>,
}

impl OtelConfig {
  pub fn as_v8(&self) -> Box<[u8]> {
    Box::new([0, 0, OtelConsoleConfig::Ignore as u8])
  }
}

#[derive(
  Default,
  Debug,
  Clone,
  Copy,
  serde::Serialize,
  serde::Deserialize,
  Eq,
  PartialEq,
  Hash,
)]
#[repr(u8)]
pub enum OtelPropagators {
  TraceContext = 0,
  Baggage = 1,
  #[default]
  None = 2,
}

#[derive(
  Debug,
  Default,
  Clone,
  Copy,
  PartialEq,
  Eq,
  serde::Serialize,
  serde::Deserialize,
)]
#[repr(u8)]
pub enum OtelConsoleConfig {
  #[default]
  Ignore = 0,
  Capture = 1,
  Replace = 2,
}

pub fn init<T>(
  _sys: &T,
  _runtime_config: OtelRuntimeConfig,
  _config: OtelConfig,
) -> deno_core::anyhow::Result<()> {
  Ok(())
}

pub fn handle_log(_record: &log::Record) {}

pub fn report_event(_name: &'static str, _data: impl std::fmt::Display) {}
