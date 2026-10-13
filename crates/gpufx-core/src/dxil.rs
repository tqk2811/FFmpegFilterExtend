//! D3D12 half of the shader cache: wgpu 30 has no on-disk pipeline cache there and
//! compiles every pipeline from HLSL (FXC, or DXC when `dxcompiler.dll` is found). gpufx
//! instead writes the HLSL itself with naga, compiles it to DXIL with `dxcompiler.dll`,
//! keeps the DXIL and hands it back through `Features::PASSTHROUGH_SHADERS`.
//!
//! Passthrough shaders are not checked by wgpu, so the HLSL must use the registers of
//! the root signature wgpu-hal builds for the pipeline layout: [`hlsl_options`] repeats
//! `create_pipeline_layout` of wgpu-hal 30 (`dx12/device.rs`) for the single bind group
//! of gpufx pipelines. Anything it does not cover returns `None` and the pipeline is
//! compiled the normal way. Re-check it when wgpu is upgraded.

use std::sync::{Mutex, OnceLock};

use naga::back::hlsl;
use windows::core::{Interface, GUID, HRESULT, PCWSTR};
use windows::Win32::Graphics::Direct3D::Dxc;

/// Shader model of the DXIL: every D3D12 adapter wgpu exposes has 6.0.
pub(crate) const SHADER_MODEL: hlsl::ShaderModel = hlsl::ShaderModel::V6_0;

/// `dxcompiler.dll`, loaded once per process.
pub(crate) struct DxcCompiler {
    compiler: Mutex<Dxc::IDxcCompiler3>,
    /// Version and commit of the DLL, part of the cache key.
    pub(crate) version: String,
    // Declared last: the compiler is released before the DLL is unloaded.
    _lib: libloading::Library,
}

// SAFETY: the COM object is only used under the mutex; DXC objects are free-threaded.
unsafe impl Send for DxcCompiler {}
unsafe impl Sync for DxcCompiler {}

impl DxcCompiler {
    /// The compiler, `None` when `dxcompiler.dll` cannot be loaded from the DLL search
    /// path (the same lookup as wgpu's).
    pub(crate) fn get() -> Option<&'static DxcCompiler> {
        static DXC: OnceLock<Option<DxcCompiler>> = OnceLock::new();
        // SAFETY: loading the DLL runs its initialisation, as wgpu-hal does.
        DXC.get_or_init(|| unsafe { Self::load() }).as_ref()
    }

    unsafe fn load() -> Option<DxcCompiler> {
        type CreateInstance = unsafe extern "system" fn(*const GUID, *const GUID, *mut *mut std::ffi::c_void) -> HRESULT;
        let lib = unsafe { libloading::Library::new("dxcompiler.dll") }.ok()?;
        let compiler = unsafe {
            let create = lib.get::<CreateInstance>(b"DxcCreateInstance\0").ok()?;
            let mut raw = std::ptr::null_mut();
            create(&Dxc::CLSID_DxcCompiler, &Dxc::IDxcCompiler3::IID, &mut raw).ok().ok()?;
            if raw.is_null() {
                return None;
            }
            Dxc::IDxcCompiler3::from_raw(raw)
        };
        let (mut major, mut minor) = (1, 0);
        if let Ok(info) = compiler.cast::<Dxc::IDxcVersionInfo>() {
            let _ = unsafe { info.GetVersion(&mut major, &mut minor) };
        }
        let mut version = format!("{major}.{minor}");
        if let Ok(info) = compiler.cast::<Dxc::IDxcVersionInfo2>() {
            let (mut count, mut hash) = (0u32, std::ptr::null_mut::<i8>());
            if unsafe { info.GetCommitInfo(&mut count, &mut hash) }.is_ok() && !hash.is_null() {
                // The string is CoTaskMemAlloc'ed; it is read once per process and left.
                let hash = unsafe { std::ffi::CStr::from_ptr(hash) }.to_string_lossy();
                version.push_str(&format!("+{count}.{hash}"));
            }
        }
        Some(DxcCompiler { compiler: Mutex::new(compiler), version, _lib: lib })
    }

    /// DXIL of the compute entry point `entry` of `hlsl`, `None` on any error.
    pub(crate) fn compile(&self, hlsl: &str, entry: &str) -> Option<Vec<u8>> {
        let wide = |s: &str| s.encode_utf16().chain([0]).collect::<Vec<u16>>();
        let entry = wide(entry);
        let target = wide(&format!("cs_{}", SHADER_MODEL.to_str()));
        // As wgpu-hal's compile_dxc, without debug info.
        let args = [
            windows::core::w!("-E"),
            PCWSTR(entry.as_ptr()),
            windows::core::w!("-T"),
            PCWSTR(target.as_ptr()),
            windows::core::w!("-HV"),
            windows::core::w!("2018"),
            windows::core::w!("-no-warnings"),
            Dxc::DXC_ARG_ENABLE_STRICTNESS,
        ];
        let buffer = Dxc::DxcBuffer { Ptr: hlsl.as_ptr().cast(), Size: hlsl.len(), Encoding: Dxc::DXC_CP_UTF8.0 };
        let compiler = self.compiler.lock().ok()?;
        // SAFETY: every pointer outlives the call.
        unsafe {
            let result: Dxc::IDxcResult = compiler.Compile(&buffer, Some(&args), None).ok()?;
            if result.GetStatus().ok()?.is_err() {
                return None;
            }
            let mut blob: Option<Dxc::IDxcBlob> = None;
            result.GetOutput(Dxc::DXC_OUT_OBJECT, &mut None, &mut blob).ok()?;
            let blob = blob?;
            let data = std::slice::from_raw_parts(blob.GetBufferPointer().cast::<u8>(), blob.GetBufferSize());
            (!data.is_empty()).then(|| data.to_vec())
        }
    }
}

/// The naga HLSL options matching the root signature wgpu-hal 30 makes for a pipeline
/// layout of the one bind group `entries` and no immediates. `None` for bindings it
/// does not repeat (dynamic offsets, arrays, external textures).
pub(crate) fn hlsl_options(entries: &[wgpu::BindGroupLayoutEntry]) -> Option<hlsl::Options> {
    let mut entries = entries.to_vec();
    // wgpu-core sorts the entries of a layout by binding.
    entries.sort_by_key(|e| e.binding);
    let mut options = hlsl::Options {
        shader_model: SHADER_MODEL,
        fake_missing_bindings: false,
        sampler_heap_target: hlsl::SamplerHeapBindTargets {
            standard_samplers: hlsl::BindTarget { space: 0, register: 0, ..Default::default() },
            comparison_samplers: hlsl::BindTarget { space: 0, register: 2048, ..Default::default() },
        },
        ..Default::default()
    };
    let (mut cbv, mut srv, mut uav) = (hlsl::BindTarget::default(), hlsl::BindTarget::default(), hlsl::BindTarget::default());
    for e in &entries {
        if e.count.is_some() {
            return None;
        }
        let target = match e.ty {
            wgpu::BindingType::Sampler(_) => continue,
            wgpu::BindingType::Buffer { has_dynamic_offset: true, .. } => return None,
            wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, .. } => &mut cbv,
            wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Storage { read_only: true }, .. }
            | wgpu::BindingType::Texture { .. } => &mut srv,
            wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Storage { read_only: false }, .. }
            | wgpu::BindingType::StorageTexture { .. } => &mut uav,
            _ => return None,
        };
        options.binding_map.insert(naga::ResourceBinding { group: 0, binding: e.binding }, *target);
        target.register += 1;
    }
    let mut samplers = 0;
    for e in entries.iter().filter(|e| matches!(e.ty, wgpu::BindingType::Sampler(_))) {
        options.binding_map.insert(
            naga::ResourceBinding { group: 0, binding: e.binding },
            // naga does not use the space of samplers: the register indexes the bind
            // group's sampler index buffer.
            hlsl::BindTarget { space: 255, register: samplers, ..Default::default() },
        );
        samplers += 1;
    }
    if samplers != 0 {
        options.sampler_buffer_binding_map.insert(hlsl::SamplerIndexBufferKey { group: 0 }, srv);
    }
    // wgpu-core always asks for FIRST_VERTEX_INSTANCE | NUM_WORK_GROUPS: the special
    // constants take the next CBV register.
    options.special_constants_binding = Some(cbv);
    Some(options)
}

/// HLSL of the compute entry point `entry` of `module` for a layout of `entries`, and
/// the entry point name to compile.
pub(crate) fn hlsl(module: &naga::Module, entries: &[wgpu::BindGroupLayoutEntry], entry: &str) -> Option<(String, String)> {
    if !module.overrides.is_empty() {
        return None;
    }
    let options = hlsl_options(entries)?;
    let info = naga::valid::Validator::new(naga::valid::ValidationFlags::all(), naga::valid::Capabilities::all()).validate(module).ok()?;
    let pipeline = hlsl::PipelineOptions { entry_point: Some((naga::ShaderStage::Compute, entry.to_string())) };
    let mut source = String::new();
    let mut reflection = hlsl::Writer::new(&mut source, &options, &pipeline).write(module, &info, None).ok()?;
    let name = reflection.entry_point_names.pop()?.ok()?;
    Some((source, name))
}
