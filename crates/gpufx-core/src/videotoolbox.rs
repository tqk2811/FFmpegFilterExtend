//! VideoToolbox frames on macOS (FFmpeg's `AV_PIX_FMT_VIDEOTOOLBOX`, a `CVPixelBufferRef`
//! in `data[3]`), read and written in place with Metal.
//!
//! A pixel buffer of FFmpeg's pools is backed by an `IOSurface`; each plane of it becomes a
//! Metal texture with `newTextureWithDescriptor:iosurface:plane:` (NV12: R8 + RG8, P010:
//! R16 + RG16), wrapped for wgpu's Metal device. Nothing is copied.
//!
//! There is no fence to wait on or signal: FFmpeg writes and reads these buffers on the CPU
//! (`hwupload`, `hwdownload` lock them) or in VideoToolbox sessions that are done with a
//! frame before handing it on. So a call waits until its GPU work is done before it
//! returns, and the next user finds the planes written.

use std::ffi::c_void;

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_io_surface::IOSurfaceRef;
use objc2_metal::{MTLDevice, MTLPixelFormat, MTLStorageMode, MTLTexture, MTLTextureDescriptor, MTLTextureType, MTLTextureUsage};
use wgpu::hal::{self, api::Metal};

use crate::frame::{ColorInfo, GpuFrame, PixelFormat};
use crate::graph::EffectGraph;
use crate::lru::Lru;
use crate::runtime::{request_adapter, Backend, FrameInfo, GpuContext};
use crate::Error;

#[link(name = "CoreVideo", kind = "framework")]
extern "C" {
    fn CVPixelBufferGetIOSurface(pixel_buffer: *mut c_void) -> *mut c_void;
    fn CVPixelBufferGetPixelFormatType(pixel_buffer: *mut c_void) -> u32;
}

const fn fourcc(s: &[u8; 4]) -> u32 {
    u32::from_be_bytes(*s)
}

/// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` / `...FullRange`.
const CV_NV12_VIDEO: u32 = fourcc(b"420v");
const CV_NV12_FULL: u32 = fourcc(b"420f");
/// `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` / `...FullRange`.
const CV_P010_VIDEO: u32 = fourcc(b"x420");
const CV_P010_FULL: u32 = fourcc(b"xf20");

/// The gpufx format of a `kCVPixelFormatType_*`, if gpufx takes it.
pub fn pixel_format(cv: u32) -> Option<PixelFormat> {
    match cv {
        CV_NV12_VIDEO | CV_NV12_FULL => Some(PixelFormat::Nv12),
        CV_P010_VIDEO | CV_P010_FULL => Some(PixelFormat::P010),
        _ => None,
    }
}

fn cv_name(cv: u32) -> String {
    let b = cv.to_be_bytes();
    if b.iter().all(|c| c.is_ascii_graphic()) {
        format!("'{}'", String::from_utf8_lossy(&b))
    } else {
        format!("{cv:#x}")
    }
}

/// A VideoToolbox frame: a `CVPixelBufferRef` backed by an `IOSurface`.
#[derive(Debug, Clone)]
pub struct VtFrame {
    /// `nv12` or `p010le` (FFmpeg's `sw_format`); must match the buffer's pixel format.
    pub format: PixelFormat,
    pub width: u32,
    pub height: u32,
    /// `CVPixelBufferRef` (`AVFrame.data[3]`), held by the caller during the call.
    pub pixel_buffer: *mut c_void,
    pub color: ColorInfo,
}

fn gpu_err(e: impl std::fmt::Display) -> Error {
    Error::Gpu(format!("VideoToolbox frames: {e}"))
}

fn mtl_format(format: wgpu::TextureFormat) -> MTLPixelFormat {
    use wgpu::TextureFormat as T;
    match format {
        T::R8Unorm => MTLPixelFormat::R8Unorm,
        T::Rg8Unorm => MTLPixelFormat::RG8Unorm,
        T::R16Unorm => MTLPixelFormat::R16Unorm,
        _ => MTLPixelFormat::RG16Unorm,
    }
}

/// Plane formats of the frames gpufx takes.
const PLANE_FORMATS: [wgpu::TextureFormat; 4] =
    [wgpu::TextureFormat::R8Unorm, wgpu::TextureFormat::Rg8Unorm, wgpu::TextureFormat::R16Unorm, wgpu::TextureFormat::Rg16Unorm];

/// What a context made by [`GpuContext::from_videotoolbox`] knows of its device.
pub(crate) struct Shared {
    /// Plane formats the effects may write (storage textures on this GPU).
    writable: Vec<wgpu::TextureFormat>,
    /// The device has 16-bit normalized formats (p010le planes).
    has16: bool,
}

impl GpuContext {
    /// A context on the system's Metal adapter, for [`EffectGraph::process_videotoolbox`].
    pub fn from_videotoolbox() -> Result<std::sync::Arc<Self>, Error> {
        let adapter = request_adapter(Backend::Metal)?;
        if adapter.get_info().backend != wgpu::Backend::Metal {
            return Err(gpu_err("no Metal adapter"));
        }
        let mut ctx = GpuContext::open_adapter(&adapter, "gpufx (VideoToolbox frames)", None)?;
        let has16 = ctx.device.features().contains(wgpu::Features::TEXTURE_FORMAT_16BIT_NORM);
        let writable = PLANE_FORMATS
            .into_iter()
            .filter(|&f| {
                (has16 || !matches!(f, wgpu::TextureFormat::R16Unorm | wgpu::TextureFormat::Rg16Unorm))
                    && adapter.get_texture_format_features(f).allowed_usages.contains(wgpu::TextureUsages::STORAGE_BINDING)
            })
            .collect();
        // Managed IOSurface textures (discrete GPUs) would need a synchronizeResource blit
        // before the CPU reads what the GPU wrote, which wgpu does not record: only unified
        // memory (Apple silicon) is taken.
        let unified = {
            let hal = unsafe { ctx.device.as_hal::<Metal>() }.ok_or_else(|| gpu_err("not a Metal device"))?;
            hal.raw_device().hasUnifiedMemory()
        };
        if !unified {
            return Err(gpu_err(format!("{} has no unified memory; VideoToolbox frames need an Apple silicon GPU", ctx.description())));
        }
        std::sync::Arc::get_mut(&mut ctx).expect("new").videotoolbox = Some(Shared { writable, has16 });
        Ok(ctx)
    }
}

/// What a plane was wrapped as. The Metal texture retains its `IOSurface`, so the surface
/// (and its ID) lives as long as the cached wrapper.
#[derive(PartialEq)]
struct ImportKey {
    surface: u32,
    plane: usize,
    format: wgpu::TextureFormat,
    size: (u32, u32),
    output: bool,
}

/// wgpu wrappers of the planes of recent VideoToolbox frames, per input then output pad.
#[derive(Default)]
pub(crate) struct ImportCache {
    pads: Vec<Lru<ImportKey, wgpu::Texture>>,
    made: usize,
}

/// A frame's buffer, checked: its surface and format.
unsafe fn surface_of<'a>(f: &VtFrame, what: &str) -> Result<&'a IOSurfaceRef, Error> {
    if f.pixel_buffer.is_null() {
        return Err(Error::Frame(format!("{what}: the CVPixelBuffer is NULL")));
    }
    let cv = CVPixelBufferGetPixelFormatType(f.pixel_buffer);
    match pixel_format(cv) {
        Some(p) if p == f.format => {}
        Some(p) => {
            return Err(Error::Frame(format!(
                "{what}: the CVPixelBuffer is {} ({}), the frame says {}",
                cv_name(cv),
                p.name(),
                f.format.name()
            )))
        }
        None => {
            return Err(Error::Frame(format!(
                "{what}: CVPixelBuffer pixel format {} is not supported; use nv12 or p010le (420v/420f/x420/xf20)",
                cv_name(cv)
            )))
        }
    }
    let surface = CVPixelBufferGetIOSurface(f.pixel_buffer) as *const IOSurfaceRef;
    surface.as_ref().ok_or_else(|| Error::Frame(format!("{what}: the CVPixelBuffer is not backed by an IOSurface")))
}

impl EffectGraph {
    /// How many wgpu wrappers of IOSurface planes were made. For tests and diagnostics.
    #[doc(hidden)]
    pub fn videotoolbox_wrappers_made(&self) -> usize {
        self.vt.made
    }

    /// Runs the graph on VideoToolbox frames, reading and writing their IOSurfaces in
    /// place, on a context made by [`GpuContext::from_videotoolbox`]. Returns once the GPU
    /// work is done (there is no fence to hand on). Without `info` the effects are bypassed.
    ///
    /// # Safety
    /// Every `pixel_buffer` must be a valid `CVPixelBufferRef`, not locked or written by
    /// anyone else during the call. Wrappers of the planes are kept for the next frames
    /// (they retain the surfaces) until the graph is dropped.
    pub unsafe fn process_videotoolbox(&mut self, inputs: &[VtFrame], outs: &[VtFrame], info: Option<&FrameInfo>) -> Result<(), Error> {
        let t_start = std::time::Instant::now();
        let ctx = self.context().clone();
        let shared = ctx.videotoolbox.as_ref().ok_or_else(|| gpu_err("the effect's device was not made for VideoToolbox frames"))?;
        let device = &ctx.device;
        let pads = inputs.len() + outs.len();
        if self.vt.pads.len() != pads {
            self.vt.pads = (0..pads).map(|_| Lru::new(crate::lru::FRAMES * 4)).collect();
        }

        // Also catches validation errors of the imports below.
        let scope = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let mut frames: Vec<GpuFrame> = Vec::with_capacity(pads);
        for (output, list) in [(false, inputs), (true, outs)] {
            for (n, f) in list.iter().enumerate() {
                let what = format!("{} {n}", if output { "output" } else { "input" });
                let surface = surface_of(f, &what)?;
                let count = f.format.plane_count();
                if surface.plane_count() != count {
                    return Err(Error::Frame(format!(
                        "{what}: the IOSurface has {} planes, {} needs {count}",
                        surface.plane_count(),
                        f.format.name()
                    )));
                }
                let pad = if output { inputs.len() + n } else { n };
                let mut planes = Vec::with_capacity(count);
                for p in 0..count {
                    let format = f.format.plane_texture_format(p);
                    if !shared.has16 && matches!(format, wgpu::TextureFormat::R16Unorm | wgpu::TextureFormat::Rg16Unorm) {
                        return Err(gpu_err(format!(
                            "{} has no 16-bit normalized textures, needed for {} frames",
                            ctx.description(),
                            f.format.name()
                        )));
                    }
                    if output && !shared.writable.contains(&format) {
                        return Err(gpu_err(format!(
                            "{} cannot write {format:?} storage textures, needed for {} output frames; use nv12, or a CPU format \
                             and hwupload after gpufx",
                            ctx.description(),
                            f.format.name()
                        )));
                    }
                    let (w, h) = f.format.plane_texture_size(p, f.width, f.height);
                    let (sw, sh) = (surface.width_of_plane(p), surface.height_of_plane(p));
                    if sw < w as usize || sh < h as usize {
                        return Err(Error::Frame(format!(
                            "{what}: plane {p} of a {}x{} frame needs {w}x{h} samples, the IOSurface plane is {sw}x{sh}",
                            f.width, f.height
                        )));
                    }
                    let key = ImportKey { surface: surface.id(), plane: p, format, size: (w, h), output };
                    if let Some(t) = self.vt.pads[pad].get(&key) {
                        planes.push(t.clone());
                        continue;
                    }
                    let t = wrap(device, surface, &key, &what)?;
                    self.vt.made += 1;
                    self.vt.pads[pad].insert(key, t.clone());
                    planes.push(t);
                }
                frames.push(GpuFrame { format: f.format, width: f.width, height: f.height, planes, color: f.color });
            }
        }
        let (ins, outs_w) = frames.split_at(inputs.len());
        let t_import = t_start.elapsed();

        let mut enc = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("gpufx videotoolbox") });
        self.allow_direct_gpu();
        let encoded = self.encode_gpu(ins, outs_w, info, &mut enc);
        let t_submit = std::time::Instant::now();
        let submitted = encoded.map(|()| ctx.queue.submit([enc.finish()]));
        self.release_frame();
        let error = pollster::block_on(scope.pop());
        let index = submitted?;
        if let Some(e) = error {
            return Err(gpu_err(e));
        }
        // FFmpeg reads the surfaces next (hwdownload, encoders) without waiting on anything.
        device.poll(wgpu::PollType::Wait { submission_index: Some(index), timeout: None }).map_err(gpu_err)?;
        if crate::profile::enabled() {
            use crate::profile::Cpu;
            self.profile_cpu(Cpu::Import, t_import);
            self.profile_cpu(Cpu::Submit, t_submit.elapsed());
            self.profile_cpu(Cpu::Total, t_start.elapsed());
        }
        Ok(())
    }
}

/// A wgpu texture on plane `key.plane` of `surface`, without a copy.
unsafe fn wrap(device: &wgpu::Device, surface: &IOSurfaceRef, key: &ImportKey, what: &str) -> Result<wgpu::Texture, Error> {
    let (w, h) = key.size;
    let raw: Retained<ProtocolObject<dyn MTLTexture>> = {
        let hal = device.as_hal::<Metal>().ok_or_else(|| gpu_err("not a Metal device"))?;
        let desc = MTLTextureDescriptor::new();
        desc.setTextureType(MTLTextureType::Type2D);
        desc.setPixelFormat(mtl_format(key.format));
        desc.setWidth(w as usize);
        desc.setHeight(h as usize);
        desc.setUsage(MTLTextureUsage::ShaderRead | MTLTextureUsage::ShaderWrite);
        desc.setStorageMode(MTLStorageMode::Shared);
        hal.raw_device().newTextureWithDescriptor_iosurface_plane(&desc, surface, key.plane).ok_or_else(|| {
            Error::Frame(format!("{what}: Metal cannot make a {w}x{h} {:?} texture on plane {} of the IOSurface", key.format, key.plane))
        })?
    };
    // The Metal texture holds its own reference to the surface; dropping the wrapper
    // releases it, nothing else to free.
    let hal_tex = hal::metal::Device::texture_from_raw(
        raw,
        key.format,
        MTLTextureType::Type2D,
        1,
        1,
        hal::CopyExtent { width: w, height: h, depth: 1 },
        None,
    );
    Ok(device.create_texture_from_hal::<Metal>(
        hal_tex,
        &wgpu::TextureDescriptor {
            label: Some("gpufx videotoolbox plane"),
            size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: key.format,
            usage: if key.output { wgpu::TextureUsages::STORAGE_BINDING } else { wgpu::TextureUsages::TEXTURE_BINDING },
            view_formats: &[],
        },
        if key.output { wgpu::TextureUses::STORAGE_WRITE_ONLY } else { wgpu::TextureUses::RESOURCE },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cv_formats_map_to_gpufx_formats() {
        assert_eq!(pixel_format(fourcc(b"420v")), Some(PixelFormat::Nv12));
        assert_eq!(pixel_format(fourcc(b"420f")), Some(PixelFormat::Nv12));
        assert_eq!(pixel_format(fourcc(b"x420")), Some(PixelFormat::P010));
        assert_eq!(pixel_format(fourcc(b"xf20")), Some(PixelFormat::P010));
        assert_eq!(pixel_format(fourcc(b"BGRA")), None);
        assert_eq!(pixel_format(fourcc(b"y420")), None);
        assert_eq!(cv_name(fourcc(b"BGRA")), "'BGRA'");
    }
}
