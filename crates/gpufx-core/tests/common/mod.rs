//! Helpers shared by the integration tests.

use gpufx_core::Backend;

/// The backend the GPU tests open: `GPUFX_TEST_BACKEND` (`vulkan`, `dx12`, ...) when set, so
/// the suite can be run once per backend; `Auto` otherwise.
pub fn backend() -> Backend {
    match std::env::var("GPUFX_TEST_BACKEND") {
        Ok(s) => s.parse().unwrap_or_else(|e| panic!("GPUFX_TEST_BACKEND: {e}")),
        Err(_) => Backend::Auto,
    }
}
