#[cfg(not(any(target_os = "ios", target_os = "android", target_os = "linux")))]
mod cell_actor;
mod remote_session;
#[cfg(not(any(target_os = "ios", target_os = "android", target_os = "linux")))]
mod runtime;
#[cfg(not(any(target_os = "ios", target_os = "android", target_os = "linux")))]
mod service;
#[cfg(any(target_os = "ios", target_os = "android", target_os = "linux"))]
#[path = "service_stub.rs"]
mod service;
#[cfg(not(any(target_os = "ios", target_os = "android", target_os = "linux")))]
mod session_runtime;
#[cfg(not(any(target_os = "ios", target_os = "android", target_os = "linux")))]
mod v8_init;

pub(crate) type TaskFailureHandler = std::sync::Arc<dyn Fn(String) + Send + Sync>;

pub use codex_code_mode_protocol::*;
pub use remote_session::ProcessOwnedCodeModeSession;
pub use remote_session::ProcessOwnedCodeModeSessionProvider;
pub use service::InProcessCodeModeSession;
pub use service::InProcessCodeModeSessionProvider;
pub use service::NoopCodeModeSessionDelegate;
#[cfg(not(any(target_os = "ios", target_os = "android", target_os = "linux")))]
pub use v8_init::V8JitMode;
#[cfg(not(any(target_os = "ios", target_os = "android", target_os = "linux")))]
pub use v8_init::initialize_v8;
