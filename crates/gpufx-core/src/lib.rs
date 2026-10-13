//! gpufx: load effect packages (zip with `manifest.json` + WGSL compute shaders) at runtime
//! and run them on any GPU wgpu supports. This crate is the engine behind the FFmpeg
//! `gpufx` filter; the C ABI lives in `gpufx-ffi`.

mod convert;
#[cfg(windows)]
pub mod d3d12;
pub mod expr;
pub mod frame;
pub mod graph;
mod lru;
pub mod manifest;
mod mips;
pub mod package;
pub mod params;
mod pool;
mod profile;
pub mod runtime;
mod shader_cache;
mod texture;
#[cfg(any(windows, all(unix, not(target_vendor = "apple"))))]
pub mod vulkan;

pub use frame::{ChromaLocation, ColorInfo, Frame, FrameMut, GpuFrame, Matrix, PixelFormat, Range};
pub use graph::{EffectChain, EffectGraph, MemoryStats, Source};
pub use manifest::{Manifest, StreamInfo};
pub use package::Package;
pub use pool::PoolStats;
pub use runtime::{Backend, Effect, FrameInfo, GpuContext, Image, ImageMut, Program};
pub use shader_cache::ShaderCacheStats;

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
    /// A graph description is malformed or wired wrongly (labels, pads, cycles).
    #[error("graph: {0}")]
    Graph(String),
}
