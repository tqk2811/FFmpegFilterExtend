//! gpufx: load effect packages (zip with `manifest.json` + WGSL compute shaders) at runtime
//! and run them on any GPU wgpu supports. This crate is the engine behind the FFmpeg
//! `gpufx` filter; the C ABI lives in `gpufx-ffi`.

pub mod manifest;
pub mod package;
pub mod params;
pub mod runtime;

pub use manifest::{Manifest, StreamInfo};
pub use package::Package;
pub use runtime::{Backend, Effect, EffectChain, FrameInfo, GpuContext, Image, ImageMut, Program};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("package: {0}")]
    Package(String),
    #[error("manifest: {0}")]
    Manifest(String),
    #[error("param: {0}")]
    Param(String),
    #[error("shader: {0}")]
    Shader(String),
    #[error("gpu: {0}")]
    Gpu(String),
    /// An input or output does not satisfy the rules of the manifest.
    #[error("unsupported: {0}")]
    Unsupported(String),
    #[error("frame: {0}")]
    Frame(String),
}
