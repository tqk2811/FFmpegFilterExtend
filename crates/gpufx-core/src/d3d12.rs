//! Direct3D 12 and Direct3D 11 frames on the GPU, without a trip through RAM.
//!
//! **D3D12** (FFmpeg's `AV_PIX_FMT_D3D12`): wgpu runs on the caller's `ID3D12Device`.
//! wgpu-hal 30 cannot wrap a device made elsewhere, but D3D12 devices are singletons per
//! adapter and process: wgpu opens the adapter with the device's LUID and gets the same
//! device back (checked). Frames are `ID3D12Resource`s read and written in place; an
//! NV12/P010 resource is wrapped once per plane with a plane slice (R8/RG8 or R16/RG16
//! views). Each frame's fence is waited for and signalled one higher, as FFmpeg's
//! `AVD3D12VAFrame.sync_ctx` expects. Resources stay in `D3D12_RESOURCE_STATE_COMMON`
//! between users: gpufx records the barriers to and from the state it needs itself, per
//! subresource, in command lists of its own around wgpu's (wgpu would transition the
//! whole resource once per plane wrapper).
//!
//! What cannot be used in place costs one GPU copy into a texture of gpufx (kept for the
//! next frame): an input that is a slice of a texture array (decoders), is larger than
//! the frame or cannot be read by shaders, and an output without
//! `D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS` (written into a texture of gpufx, then
//! copied into the planes).
//!
//! **D3D11** (`AV_PIX_FMT_D3D11`): wgpu has no D3D11 backend. Textures created with
//! `D3D11_RESOURCE_MISC_SHARED_NTHANDLE` (the output frames gpufx makes) are opened in
//! wgpu's D3D12 device on the same adapter with `OpenSharedHandle`, without a copy;
//! other input textures (hwupload, decoders) are first copied once on the D3D11
//! immediate context into a shared texture of gpufx. A fence shared by both devices
//! orders the D3D11 work before and after the D3D12 work on the GPU.

use std::ffi::c_void;
use std::sync::{Arc, Mutex};

use wgpu::hal::{self, api::Dx12, CommandEncoder as _};
use windows::core::{IUnknown, Interface, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, GENERIC_ALL, HANDLE, LUID};
use windows::Win32::Graphics::Direct3D11::{
    ID3D11Device, ID3D11Device5, ID3D11DeviceContext, ID3D11DeviceContext4, ID3D11Fence, ID3D11Texture2D, D3D11_BIND_SHADER_RESOURCE,
    D3D11_BOX, D3D11_RESOURCE_MISC_SHARED, D3D11_RESOURCE_MISC_SHARED_NTHANDLE, D3D11_TEXTURE2D_DESC, D3D11_USAGE_DEFAULT,
};
use windows::Win32::Graphics::Direct3D12::{
    ID3D12Device, ID3D12Fence, ID3D12Resource, D3D12_FENCE_FLAG_SHARED, D3D12_RESOURCE_DIMENSION_TEXTURE2D,
    D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS, D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT, DXGI_FORMAT_NV12, DXGI_FORMAT_P010, DXGI_FORMAT_R16G16B16A16_UNORM, DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_SAMPLE_DESC,
};
use windows::Win32::Graphics::Dxgi::{IDXGIDevice, IDXGIResource1, DXGI_SHARED_RESOURCE_READ, DXGI_SHARED_RESOURCE_WRITE};

use crate::frame::{ColorInfo, GpuFrame, PixelFormat};
use crate::graph::EffectGraph;
use crate::runtime::{FrameInfo, GpuContext};
use crate::Error;

/// A D3D12 frame, as `AVD3D12VAFrame` describes it.
#[derive(Debug, Clone)]
pub struct D3d12Frame {
    pub format: PixelFormat,
    pub width: u32,
    pub height: u32,
    /// `ID3D12Resource *`: NV12 or P010 (the planes are its plane slices), or RGBA8 /
    /// RGBA16 for `rgba` / `rgba64le`.
    pub resource: *mut c_void,
    /// Array slice of the frame in `resource` (`subresource_index`).
    pub subresource: u32,
    /// `ID3D12Fence *` of the frame and the value to wait for; after the call, the value
    /// gpufx signals when it is done with the frame (one more).
    pub fence: *mut c_void,
    pub fence_value: u64,
    pub color: ColorInfo,
}

/// A D3D11 frame, as `AVFrame.data[0]` (texture) and `data[1]` (array slice) give it.
#[derive(Debug, Clone)]
pub struct D3d11Frame {
    pub format: PixelFormat,
    pub width: u32,
    pub height: u32,
    /// `ID3D11Texture2D *`.
    pub texture: *mut c_void,
    pub array_slice: u32,
    pub color: ColorInfo,
}

/// DXGI format of a whole frame resource of `format`, if gpufx reads it in place.
fn dxgi_format(format: PixelFormat) -> Option<DXGI_FORMAT> {
    Some(match format {
        PixelFormat::Nv12 => DXGI_FORMAT_NV12,
        PixelFormat::P010 => DXGI_FORMAT_P010,
        PixelFormat::Rgba => DXGI_FORMAT_R8G8B8A8_UNORM,
        PixelFormat::Rgba64 => DXGI_FORMAT_R16G16B16A16_UNORM,
        _ => return None,
    })
}

fn gpu_err(e: impl std::fmt::Display) -> Error {
    Error::Gpu(format!("shared D3D12 device: {e}"))
}

/// COM interfaces held by the context and the graphs; D3D12 objects are free threaded,
/// and the D3D11 ones are only used under the caller's device lock (see `process_d3d11`).
struct Com<T>(T);
unsafe impl<T> Send for Com<T> {}
unsafe impl<T> Sync for Com<T> {}

/// What a context made by [`GpuContext::from_d3d12`] or [`GpuContext::from_d3d11`]
/// keeps of the caller's device.
pub(crate) struct Shared {
    device: Com<ID3D12Device>,
    d3d11: Option<Mutex<D3d11>>,
    /// Held while fences are staged and submitted; true once a submission failed.
    submit: Mutex<bool>,
}

struct D3d11 {
    context: Com<ID3D11DeviceContext4>,
    device: Com<ID3D11Device>,
    /// One fence, opened in both devices; `value` is its last signalled value.
    fence12: Com<ID3D12Fence>,
    fence11: Com<ID3D11Fence>,
    value: u64,
    /// Shareable D3D11 textures opened in D3D12, by texture (the D3D11 reference keeps
    /// the address from being reused). Bounded: the oldest goes first.
    opened: Vec<(usize, Com<ID3D11Texture2D>, Com<ID3D12Resource>)>,
}

const OPENED_MAX: usize = 64;

unsafe fn borrow<T: Interface>(p: *mut c_void, what: &str) -> Result<T, Error> {
    T::from_raw_borrowed(&p).cloned().ok_or_else(|| Error::Frame(format!("{what} is NULL")))
}

fn same_object(a: &impl Interface, b: &impl Interface) -> bool {
    match (a.cast::<IUnknown>(), b.cast::<IUnknown>()) {
        (Ok(a), Ok(b)) => a.as_raw() == b.as_raw(),
        _ => false,
    }
}

/// wgpu's DX12 adapter with this LUID, opened.
fn open_luid(luid: LUID) -> Result<Arc<GpuContext>, Error> {
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::DX12,
        // The device is FFmpeg's too: no debug layer or GPU-based validation switched on
        // (or debug names) behind its back, whatever the environment says.
        flags: wgpu::InstanceFlags::from_env_or_default()
            - (wgpu::InstanceFlags::VALIDATION | wgpu::InstanceFlags::GPU_BASED_VALIDATION | wgpu::InstanceFlags::DEBUG),
        backend_options: wgpu::BackendOptions::from_env_or_default(),
        ..wgpu::InstanceDescriptor::new_without_display_handle()
    });
    let adapters = pollster::block_on(instance.enumerate_adapters(wgpu::Backends::DX12));
    let mut names = Vec::new();
    for adapter in adapters {
        let ours =
            unsafe { adapter.as_hal::<Dx12>() }.is_some_and(|a| unsafe { a.raw_adapter().GetDesc() }.is_ok_and(|d| d.AdapterLuid == luid));
        if ours {
            return GpuContext::open_adapter(&adapter, "gpufx (shared D3D12 device)", None);
        }
        names.push(adapter.get_info().name);
    }
    Err(gpu_err(format!(
        "the device's adapter is not one wgpu uses (wgpu has: {}); pick another adapter, e.g. -init_hw_device d3d12va=dx:1",
        if names.is_empty() { "none".to_string() } else { names.join(", ") }
    )))
}

fn raw_device(ctx: &GpuContext) -> Result<ID3D12Device, Error> {
    let hal = unsafe { ctx.device.as_hal::<Dx12>() }.ok_or_else(|| gpu_err("not a D3D12 device"))?;
    Ok(hal.raw_device().clone())
}

impl GpuContext {
    /// A context on the caller's D3D12 device (FFmpeg's `AVD3D12VADeviceContext.device`),
    /// for [`EffectGraph::process_d3d12`]. The device must outlive the context.
    ///
    /// # Safety
    /// `device` must be a valid `ID3D12Device *`.
    pub unsafe fn from_d3d12(device: *mut c_void) -> Result<Arc<Self>, Error> {
        let theirs: ID3D12Device = borrow(device, "device")?;
        let mut ctx = open_luid(theirs.GetAdapterLuid())?;
        let ours = raw_device(&ctx)?;
        if !same_object(&ours, &theirs) {
            return Err(gpu_err(
                "wgpu got another ID3D12Device for the adapter than the caller's (another D3D12 runtime, such as an Agility SDK, \
                 is loaded?)",
            ));
        }
        Arc::get_mut(&mut ctx).expect("new").d3d12 = Some(Shared { device: Com(ours), d3d11: None, submit: Mutex::new(false) });
        Ok(ctx)
    }

    /// A context on wgpu's D3D12 device of the adapter of the caller's D3D11 device
    /// (FFmpeg's `AVD3D11VADeviceContext`), for [`EffectGraph::process_d3d11`]. Needs
    /// D3D11.4 shared fences (Windows 10 1703 or later). The device must outlive the
    /// context.
    ///
    /// # Safety
    /// `device` and `context` must be a valid `ID3D11Device *` and its immediate context.
    pub unsafe fn from_d3d11(device: *mut c_void, context: *mut c_void) -> Result<Arc<Self>, Error> {
        let dev11: ID3D11Device = borrow(device, "device")?;
        let ctx11: ID3D11DeviceContext = borrow(context, "device_context")?;
        let dev5: ID3D11Device5 = dev11.cast().map_err(|_| gpu_err("the D3D11 device has no shared fences (ID3D11Device5, D3D11.4)"))?;
        let ctx4: ID3D11DeviceContext4 =
            ctx11.cast().map_err(|_| gpu_err("the D3D11 device context has no fences (ID3D11DeviceContext4, D3D11.4)"))?;
        let luid = dev11.cast::<IDXGIDevice>().and_then(|d| d.GetAdapter()).and_then(|a| a.GetDesc()).map_err(gpu_err)?.AdapterLuid;
        let mut ctx = open_luid(luid)?;
        let dev12 = raw_device(&ctx)?;
        let fence12: ID3D12Fence = dev12.CreateFence(0, D3D12_FENCE_FLAG_SHARED).map_err(gpu_err)?;
        let handle = dev12.CreateSharedHandle(&fence12, None, GENERIC_ALL.0, PCWSTR::null()).map_err(gpu_err)?;
        let mut fence11: Option<ID3D11Fence> = None;
        let opened = dev5.OpenSharedFence(handle, &mut fence11);
        let _ = CloseHandle(handle);
        opened.map_err(|e| gpu_err(format!("cannot open the shared fence in D3D11: {e}")))?;
        let fence11 = fence11.ok_or_else(|| gpu_err("no shared fence"))?;
        let d3d11 =
            D3d11 { context: Com(ctx4), device: Com(dev11), fence12: Com(fence12), fence11: Com(fence11), value: 0, opened: Vec::new() };
        Arc::get_mut(&mut ctx).expect("new").d3d12 =
            Some(Shared { device: Com(dev12), d3d11: Some(Mutex::new(d3d11)), submit: Mutex::new(false) });
        Ok(ctx)
    }
}

/// gpufx textures standing in for frames that cannot be used in place, and the last
/// submission on D3D12 frames.
/// (output?, pad, plane, format, width, height) of a texture standing in for a plane.
type ScratchKey = (bool, usize, usize, wgpu::TextureFormat, u32, u32);
/// A D3D11 input's shared copy: (pad, (width, height, DXGI format)), D3D11 and D3D12 sides.
type Staging = (usize, (u32, u32, i32), Com<ID3D11Texture2D>, Com<ID3D12Resource>);

#[derive(Default)]
pub(crate) struct GraphState {
    /// (output?, pad, plane, format, width, height) and the texture.
    scratch: Vec<(ScratchKey, wgpu::Texture)>,
    /// D3D11 inputs: (pad, texture desc) and the shared texture, opened in D3D12.
    staging: Vec<Staging>,
    last: Option<wgpu::SubmissionIndex>,
}

impl GraphState {
    fn scratch(&mut self, device: &wgpu::Device, key: ScratchKey) -> wgpu::Texture {
        if let Some((_, t)) = self.scratch.iter().find(|(k, _)| *k == key) {
            return t.clone();
        }
        let (output, _, _, format, width, height) = key;
        let usage = if output {
            wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC
        } else {
            wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST
        };
        let t = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("gpufx d3d12 copy"),
            size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage,
            view_formats: &[],
        });
        self.scratch.push((key, t.clone()));
        t
    }
}

/// A frame resource of the device, checked.
struct Res {
    format: PixelFormat,
    width: u32,
    height: u32,
    resource: ID3D12Resource,
    slice: u32,
    color: ColorInfo,
    /// Size and array size of the resource.
    size: (u32, u32, u32),
    /// Read or written in place; else through a texture of gpufx and one copy.
    direct: bool,
}

unsafe fn check(
    f: (PixelFormat, u32, u32, ID3D12Resource, u32, ColorInfo),
    output: bool,
    what: &str,
    dev: &ID3D12Device,
) -> Result<Res, Error> {
    let (format, width, height, resource, slice, color) = f;
    let want = dxgi_format(format).ok_or_else(|| {
        Error::Frame(format!("{what}: D3D12/D3D11 frames of {} are not supported; use nv12, p010le, rgba or rgba64le", format.name()))
    })?;
    let mut owner: Option<ID3D12Device> = None;
    resource.GetDevice(&mut owner).map_err(gpu_err)?;
    if !owner.is_some_and(|o| same_object(&o, dev)) {
        return Err(Error::Frame(format!("{what}: the resource belongs to another D3D12 device than the effect's")));
    }
    let d = resource.GetDesc();
    if d.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D || d.Format != want || d.SampleDesc.Count != 1 {
        return Err(Error::Frame(format!(
            "{what}: a {} frame must be a 2D DXGI_FORMAT {} texture, got dimension {} format {}",
            format.name(),
            want.0,
            d.Dimension.0,
            d.Format.0
        )));
    }
    // Subresource indices and the plane wrappers assume one mip level (FFmpeg makes no others).
    if d.MipLevels != 1 {
        return Err(Error::Frame(format!("{what}: textures with {} mip levels are not supported", d.MipLevels)));
    }
    let size = (d.Width as u32, d.Height, u32::from(d.DepthOrArraySize));
    if (d.Width as u32) < width || d.Height < height || slice >= size.2 || width == 0 || height == 0 {
        return Err(Error::Frame(format!(
            "{what}: a {width}x{height} frame at slice {slice} does not fit the {}x{} texture of {} slices",
            size.0, size.1, size.2
        )));
    }
    let exact = size == (width, height, 1);
    let direct = exact
        && if output {
            d.Flags.contains(D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS)
        } else {
            !d.Flags.contains(D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE)
        };
    Ok(Res { format, width, height, resource, slice, color, size, direct })
}

/// What a wrapper is used for: the wgpu usage, and the state it is (made to be) in.
fn plan(output: bool, direct: bool) -> (wgpu::TextureUsages, wgpu::TextureUses) {
    use wgpu::{TextureUsages as U, TextureUses as S};
    match (output, direct) {
        (false, true) => (U::TEXTURE_BINDING, S::RESOURCE),
        (false, false) => (U::COPY_SRC, S::COPY_SRC),
        (true, true) => (U::STORAGE_BINDING, S::STORAGE_WRITE_ONLY),
        (true, false) => (U::COPY_DST, S::COPY_DST),
    }
}

impl EffectGraph {
    /// Runs the graph on D3D12 frames of the device the graph's context shares
    /// ([`GpuContext::from_d3d12`]), reading and writing the resources in place where
    /// they allow it (see the module documentation). One submission waits for every
    /// frame's fence at its value and signals one more; `fence_value` of every frame is
    /// updated. Returns once the work is submitted; the next call waits until it is done
    /// (an upload into a frame gpufx still reads would not wait for its fence).
    ///
    /// # Safety
    /// The resources and fences must be valid objects of that device, the frames in
    /// `D3D12_RESOURCE_STATE_COMMON` once their fences reach the values (they are left in
    /// it), and not used by others until then.
    pub unsafe fn process_d3d12(
        &mut self,
        inputs: &mut [D3d12Frame],
        outs: &mut [D3d12Frame],
        info: Option<&FrameInfo>,
    ) -> Result<(), Error> {
        let ctx = self.context().clone();
        let shared = ctx.d3d12.as_ref().ok_or_else(|| Error::Gpu("D3D12 frames need a graph opened on a shared D3D12 device".into()))?;
        if shared.d3d11.is_some() {
            return Err(Error::Gpu("this graph runs on a D3D11 device; give it D3D11 frames".into()));
        }
        if let Some(last) = self.dx.last.take() {
            ctx.device.poll(wgpu::PollType::Wait { submission_index: Some(last), timeout: None }).map_err(gpu_err)?;
        }
        let dev = &shared.device.0;
        let mut ins = Vec::new();
        let mut os = Vec::new();
        let mut fences: Vec<(ID3D12Fence, u64)> = Vec::new();
        for (output, list, res) in [(false, &*inputs, &mut ins), (true, &*outs, &mut os)] {
            for (n, f) in list.iter().enumerate() {
                let what = format!("{} {n}", if output { "output" } else { "input" });
                let r: ID3D12Resource = borrow(f.resource, &format!("{what}: resource"))?;
                res.push(check((f.format, f.width, f.height, r, f.subresource, f.color), output, &what, dev)?);
                let fence: ID3D12Fence = borrow(f.fence, &format!("{what}: fence"))?;
                match fences.iter_mut().find(|(x, _)| x.as_raw() == fence.as_raw()) {
                    Some((_, v)) => *v = (*v).max(f.fence_value),
                    None => fences.push((fence, f.fence_value)),
                }
            }
        }
        let sync: Vec<(ID3D12Fence, u64, u64)> = fences.into_iter().map(|(f, v)| (f, v, v + 1)).collect();
        let index = self.run_dx12(&ctx, shared, &ins, &os, info, &sync)?;
        self.dx.last = Some(index);
        for f in inputs.iter_mut().chain(outs.iter_mut()) {
            if let Some((_, _, s)) = sync.iter().find(|(x, _, _)| x.as_raw() == f.fence) {
                f.fence_value = *s;
            }
        }
        Ok(())
    }

    /// Runs the graph on D3D11 frames of the device the graph's context was made for
    /// ([`GpuContext::from_d3d11`]). Shareable textures (`D3D11_RESOURCE_MISC_SHARED_NTHANDLE`)
    /// are used in place; other inputs are copied once into a shared texture of gpufx,
    /// and outputs must be shareable. The D3D11 work queued after the call (on the
    /// immediate context) waits for the effects on the GPU.
    ///
    /// # Safety
    /// The textures must be valid textures of that device; the caller holds the lock of
    /// the immediate context (FFmpeg's `AVD3D11VADeviceContext.lock`) during the call.
    pub unsafe fn process_d3d11(&mut self, inputs: &[D3d11Frame], outs: &[D3d11Frame], info: Option<&FrameInfo>) -> Result<(), Error> {
        let ctx = self.context().clone();
        let shared = ctx.d3d12.as_ref().ok_or_else(|| Error::Gpu("D3D11 frames need a graph opened on a D3D11 device".into()))?;
        let mut d11 = shared
            .d3d11
            .as_ref()
            .ok_or_else(|| Error::Gpu("this graph runs on a D3D12 device; give it D3D12 frames".into()))?
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        let dev = &shared.device.0;
        let mut ins = Vec::new();
        let mut os = Vec::new();
        for (output, list, res) in [(false, inputs, &mut ins), (true, outs, &mut os)] {
            for (n, f) in list.iter().enumerate() {
                let what = format!("{} {n}", if output { "output" } else { "input" });
                let tex: ID3D11Texture2D = borrow(f.texture, &format!("{what}: texture"))?;
                let mut d = D3D11_TEXTURE2D_DESC::default();
                tex.GetDesc(&mut d);
                let shareable = d.MiscFlags & D3D11_RESOURCE_MISC_SHARED_NTHANDLE.0 as u32 != 0;
                let (resource, slice) = if shareable {
                    (d11.open(dev, &tex)?, f.array_slice)
                } else if output {
                    return Err(Error::Frame(format!(
                        "{what}: D3D11 output frames must be shareable (D3D11_RESOURCE_MISC_SHARED_NTHANDLE); gpufx makes its own"
                    )));
                } else {
                    // One copy into a shared texture of gpufx, on the immediate context.
                    let key = (f.width, f.height, d.Format.0);
                    let found = self.dx.staging.iter().position(|(pad, k, _, _)| *pad == n && *k == key);
                    let i = match found {
                        Some(i) => i,
                        None => {
                            self.dx.staging.retain(|(pad, _, _, _)| *pad != n);
                            let desc = D3D11_TEXTURE2D_DESC {
                                Width: f.width,
                                Height: f.height,
                                MipLevels: 1,
                                ArraySize: 1,
                                Format: d.Format,
                                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                                Usage: D3D11_USAGE_DEFAULT,
                                BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
                                CPUAccessFlags: 0,
                                MiscFlags: (D3D11_RESOURCE_MISC_SHARED.0 | D3D11_RESOURCE_MISC_SHARED_NTHANDLE.0) as u32,
                            };
                            let mut staging: Option<ID3D11Texture2D> = None;
                            d11.device.0.CreateTexture2D(&desc, None, Some(&mut staging)).map_err(|e| {
                                gpu_err(format!("{what}: cannot make a shared D3D11 texture of DXGI_FORMAT {}: {e}", d.Format.0))
                            })?;
                            let staging = staging.ok_or_else(|| gpu_err("no texture"))?;
                            let r = share(dev, &staging)?;
                            self.dx.staging.push((n, key, Com(staging), Com(r)));
                            self.dx.staging.len() - 1
                        }
                    };
                    let (_, _, staging, r) = &self.dx.staging[i];
                    if d.MipLevels != 1 {
                        return Err(Error::Frame(format!("{what}: textures with {} mip levels are not supported", d.MipLevels)));
                    }
                    // Planar boxes must cover whole chroma samples.
                    debug_assert!(
                        f.format.plane_count() == 1 || (f.width % 2 == 0 && f.height % 2 == 0),
                        "odd {}x{} box for a planar texture",
                        f.width,
                        f.height
                    );
                    let src = f.array_slice;
                    let region = D3D11_BOX { left: 0, top: 0, front: 0, right: f.width, bottom: f.height, back: 1 };
                    d11.context.0.CopySubresourceRegion(&staging.0, 0, 0, 0, 0, &tex, src, Some(&region));
                    (r.0.clone(), 0)
                };
                res.push(check((f.format, f.width, f.height, resource, slice, f.color), output, &what, dev)?);
            }
        }
        // D3D11 work so far, then gpufx, then what D3D11 queues next.
        let v = d11.value + 1;
        d11.context.0.Signal(&d11.fence11.0, v).map_err(gpu_err)?;
        d11.context.0.Flush();
        d11.value = v;
        let sync = [(d11.fence12.0.clone(), v, v + 1)];
        let run = self.run_dx12(&ctx, shared, &ins, &os, info, &sync);
        if run.is_ok() {
            d11.value = v + 1;
            d11.context.0.Wait(&d11.fence11.0, v + 1).map_err(gpu_err)?;
        }
        run.map(|_| ())
    }

    /// One submission: barriers to the states needed, copies into gpufx textures, the
    /// graph, copies out, barriers back to COMMON; waits and signals `sync`
    /// (fence, wait value, signal value).
    unsafe fn run_dx12(
        &mut self,
        ctx: &Arc<GpuContext>,
        shared: &Shared,
        ins: &[Res],
        outs: &[Res],
        info: Option<&FrameInfo>,
        sync: &[(ID3D12Fence, u64, u64)],
    ) -> Result<wgpu::SubmissionIndex, Error> {
        if *shared.submit.lock().unwrap_or_else(|p| p.into_inner()) {
            return Err(Error::Gpu("an earlier D3D12 submission failed; the shared device is no longer used".into()));
        }
        let device = &ctx.device;
        let scope = device.push_error_scope(wgpu::ErrorFilter::Validation);

        // Plane wrappers (nothing owned, no copy) and the GpuFrames the graph sees.
        struct Plane {
            wrapper: wgpu::Texture,
            scratch: Option<wgpu::Texture>,
            slice: u32,
            size: (u32, u32),
        }
        let mut frames: [Vec<GpuFrame>; 2] = [Vec::new(), Vec::new()];
        let mut planes: [Vec<Plane>; 2] = [Vec::new(), Vec::new()];
        // Barrier textures, one per (resource, slice), and the state each is used in.
        let mut barriers: Vec<(usize, u32, hal::dx12::Texture, wgpu::TextureUses)> = Vec::new();
        for (o, list) in [ins, outs].into_iter().enumerate() {
            let output = o == 1;
            for (n, r) in list.iter().enumerate() {
                let (usage, state) = plan(output, r.direct);
                let count = r.format.plane_count();
                let planar = count > 1;
                let mut textures = Vec::new();
                for p in 0..count {
                    let format = r.format.plane_texture_format(p);
                    let (w, h) = r.format.plane_texture_size(p, r.width, r.height);
                    let (rw, rh) = r.format.plane_texture_size(p, r.size.0, r.size.1);
                    let size = wgpu::Extent3d { width: rw, height: rh, depth_or_array_layers: r.size.2 };
                    let mut hal_tex =
                        hal::dx12::Device::texture_from_raw(r.resource.clone(), format, wgpu::TextureDimension::D2, size, 1, 1);
                    if planar {
                        hal_tex = hal_tex.with_plane_slice(p as u32);
                    }
                    let wrapper = device.create_texture_from_hal::<Dx12>(
                        hal_tex,
                        &wgpu::TextureDescriptor {
                            label: Some("gpufx d3d12 plane"),
                            size,
                            mip_level_count: 1,
                            sample_count: 1,
                            dimension: wgpu::TextureDimension::D2,
                            format,
                            usage,
                            view_formats: &[],
                        },
                        state,
                    );
                    let scratch = (!r.direct).then(|| self.dx.scratch(device, (output, n, p, format, w, h)));
                    textures.push(scratch.clone().unwrap_or_else(|| wrapper.clone()));
                    planes[o].push(Plane { wrapper, scratch, slice: r.slice, size: (w, h) });
                }
                frames[o].push(GpuFrame { format: r.format, width: r.width, height: r.height, planes: textures, color: r.color });
                let key = r.resource.as_raw() as usize;
                if !barriers.iter().any(|(k, s, _, _)| *k == key && *s == r.slice) {
                    let whole = match r.format {
                        PixelFormat::Nv12 => wgpu::TextureFormat::NV12,
                        PixelFormat::P010 => wgpu::TextureFormat::P010,
                        f => f.plane_texture_format(0),
                    };
                    let size = wgpu::Extent3d { width: r.size.0, height: r.size.1, depth_or_array_layers: r.size.2 };
                    let t = hal::dx12::Device::texture_from_raw(r.resource.clone(), whole, wgpu::TextureDimension::D2, size, 1, 1);
                    barriers.push((key, r.slice, t, state));
                }
            }
        }

        // COMMON -> the state of each use, per subresource of the frame's slice.
        let transition = |enc: &mut wgpu::CommandEncoder, to_common: bool| {
            enc.as_hal_mut::<Dx12, _, _>(|enc| {
                if let Some(enc) = enc {
                    enc.transition_textures(barriers.iter().map(|(_, slice, t, state)| {
                        let (from, to) =
                            if to_common { (*state, wgpu::TextureUses::UNINITIALIZED) } else { (wgpu::TextureUses::UNINITIALIZED, *state) };
                        hal::TextureBarrier {
                            texture: t,
                            range: wgpu::ImageSubresourceRange {
                                aspect: wgpu::TextureAspect::All,
                                base_mip_level: 0,
                                mip_level_count: Some(1),
                                base_array_layer: *slice,
                                array_layer_count: Some(1),
                            },
                            usage: hal::StateTransition { from, to },
                        }
                    }));
                }
            });
        };
        let mut pre = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("gpufx d3d12 states") });
        transition(&mut pre, false);
        let mut enc = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("gpufx d3d12") });
        let copy = |enc: &mut wgpu::CommandEncoder, p: &Plane, output: bool| {
            let Some(scratch) = &p.scratch else { return };
            let frame = wgpu::TexelCopyTextureInfo {
                texture: &p.wrapper,
                mip_level: 0,
                origin: wgpu::Origin3d { x: 0, y: 0, z: p.slice },
                aspect: wgpu::TextureAspect::All,
            };
            let own = wgpu::TexelCopyTextureInfo {
                texture: scratch,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            };
            let extent = wgpu::Extent3d { width: p.size.0, height: p.size.1, depth_or_array_layers: 1 };
            if output {
                enc.copy_texture_to_texture(own, frame, extent);
            } else {
                enc.copy_texture_to_texture(frame, own, extent);
            }
        };
        for p in &planes[0] {
            copy(&mut enc, p, false);
        }
        let [in_frames, out_frames] = &frames;
        self.encode_gpu(in_frames, out_frames, info, &mut enc)?;
        for p in &planes[1] {
            copy(&mut enc, p, true);
        }
        let mut post = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("gpufx d3d12 states back") });
        transition(&mut post, true);
        let buffers = [pre.finish(), enc.finish(), post.finish()];

        let mut poisoned = shared.submit.lock().unwrap_or_else(|p| p.into_inner());
        {
            let queue = ctx.queue.as_hal::<Dx12>().ok_or_else(|| gpu_err("not a D3D12 queue"))?;
            for (f, wait, signal) in sync {
                queue.add_wait_fence(f.clone(), *wait);
                queue.add_signal_fence(f.clone(), *signal);
            }
        }
        let index = ctx.queue.submit(buffers);
        // A submission wgpu refused leaves the fences staged: take them back so no later
        // submission signals stale values, and stop using the device.
        let mut left = false;
        {
            let queue = ctx.queue.as_hal::<Dx12>().ok_or_else(|| gpu_err("not a D3D12 queue"))?;
            for (f, _, _) in sync {
                left |= queue.remove_wait_fence(f);
                left |= queue.remove_signal_fence(f);
            }
        }
        let error = pollster::block_on(scope.pop());
        if left || error.is_some() {
            *poisoned = true;
            let why = error.map_or_else(|| "it was not submitted".to_string(), |e| e.to_string());
            return Err(Error::Gpu(format!("D3D12 submission failed ({why}); the shared device is no longer used")));
        }
        Ok(index)
    }
}

/// A shareable D3D11 texture opened in the D3D12 device.
unsafe fn share(dev: &ID3D12Device, tex: &ID3D11Texture2D) -> Result<ID3D12Resource, Error> {
    let handle: HANDLE = tex
        .cast::<IDXGIResource1>()
        .and_then(|r| r.CreateSharedHandle(None, DXGI_SHARED_RESOURCE_READ.0 | DXGI_SHARED_RESOURCE_WRITE.0, PCWSTR::null()))
        .map_err(|e| gpu_err(format!("cannot share the D3D11 texture: {e}")))?;
    let mut r: Option<ID3D12Resource> = None;
    let opened = dev.OpenSharedHandle(handle, &mut r);
    let _ = CloseHandle(handle);
    opened.map_err(|e| gpu_err(format!("cannot open the D3D11 texture in D3D12: {e}")))?;
    r.ok_or_else(|| gpu_err("no resource"))
}

impl D3d11 {
    unsafe fn open(&mut self, dev: &ID3D12Device, tex: &ID3D11Texture2D) -> Result<ID3D12Resource, Error> {
        let key = tex.as_raw() as usize;
        if let Some((_, _, r)) = self.opened.iter().find(|(k, _, _)| *k == key) {
            return Ok(r.0.clone());
        }
        let r = share(dev, tex)?;
        if self.opened.len() >= OPENED_MAX {
            self.opened.remove(0);
        }
        self.opened.push((key, Com(tex.clone()), Com(r.clone())));
        Ok(r)
    }
}
