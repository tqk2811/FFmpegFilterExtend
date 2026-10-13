//! Zero-copy Vulkan frames: wgpu runs on a Vulkan device made by someone else (FFmpeg's
//! `AVVulkanDeviceContext`) and reads and writes its `VkImage`s directly, synchronised
//! with their timeline semaphores.
//!
//! wgpu-hal decides what it may use from what the physical device *supports*, but a
//! device made elsewhere only has what its creator *enabled* (FFmpeg does not enable
//! `robustBufferAccess`, for instance, and wgpu would then drop its own bounds checks).
//! So wgpu sees the physical device through a `vkGetInstanceProcAddr` that reports only
//! the extensions enabled on the device, and features masked by the enabled ones.

use std::ffi::{c_char, c_void, CStr, CString};
use std::mem::size_of;
use std::sync::{Arc, Mutex};

use ash::vk::{self, Handle};
use wgpu::hal::{self, api::Vulkan};

use crate::frame::{ColorInfo, GpuFrame, PixelFormat};
use crate::graph::EffectGraph;
use crate::runtime::{device_limits, FrameInfo, GpuContext};
use crate::Error;

/// A Vulkan device to share, as `AVVulkanDeviceContext` describes it.
#[derive(Debug, Clone)]
pub struct VulkanDevice {
    /// `PFN_vkGetInstanceProcAddr` of the loader the instance comes from.
    pub get_instance_proc_addr: *const c_void,
    /// `VkInstance`, `VkPhysicalDevice` and `VkDevice` handles.
    pub instance: *mut c_void,
    pub physical_device: *mut c_void,
    pub device: *mut c_void,
    /// Vulkan version the instance was created with (at least 1.1, FFmpeg asks 1.3).
    pub api_version: u32,
    pub instance_extensions: Vec<String>,
    pub device_extensions: Vec<String>,
    /// `VkPhysicalDeviceFeatures2` chain of what is enabled on the device. Read during
    /// [`GpuContext::from_vulkan`] only.
    pub enabled_features: *const c_void,
    /// Queue gpufx submits to: a family with compute, and the index of the queue in it.
    /// The caller keeps other threads off this queue while gpufx submits.
    pub queue_family: u32,
    pub queue_index: u32,
    /// `VkDeviceQueueCreateFlags` the queues were created with.
    pub queue_flags: u32,
}

/// One `VkImage` of a frame, one per plane.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VulkanPlane {
    pub image: u64,
    /// `VkFormat` of the image: [`PixelFormat::plane_texture_format`] as a Vulkan format
    /// (`VK_FORMAT_R8_UNORM`, `VK_FORMAT_R8G8_UNORM`, ...).
    pub format: i32,
    /// `VkImageLayout` before the call; after it, the layout the image was left in.
    pub layout: i32,
    /// Timeline semaphore of the image and the value to wait for; after the call, the
    /// value gpufx signals when it is done with the image (one more).
    pub semaphore: u64,
    pub value: u64,
    /// Queue family owning the image, or `VK_QUEUE_FAMILY_IGNORED` (concurrent sharing).
    pub queue_family: u32,
}

/// A frame of `VkImage`s, one per plane of `format`.
#[derive(Debug, Clone)]
pub struct VulkanFrame {
    pub format: PixelFormat,
    pub width: u32,
    pub height: u32,
    pub planes: Vec<VulkanPlane>,
    pub color: ColorInfo,
}

/// The layout every image is left in, so the next user knows it.
pub const LAYOUT_AFTER: i32 = vk::ImageLayout::GENERAL.as_raw();

fn vk_format(format: wgpu::TextureFormat) -> vk::Format {
    use wgpu::TextureFormat as T;
    match format {
        T::R8Unorm => vk::Format::R8_UNORM,
        T::Rg8Unorm => vk::Format::R8G8_UNORM,
        T::Rgba8Unorm => vk::Format::R8G8B8A8_UNORM,
        T::R16Unorm => vk::Format::R16_UNORM,
        T::Rg16Unorm => vk::Format::R16G16_UNORM,
        _ => vk::Format::R16G16B16A16_UNORM,
    }
}

/// Plane `plane` of a `format` frame as `VkFormat`.
pub fn plane_vk_format(format: PixelFormat, plane: usize) -> i32 {
    vk_format(format.plane_texture_format(plane)).as_raw()
}

// ---- the physical device as wgpu sees it ----

/// The real entry points, and what each shared device has enabled.
struct State {
    gipa: Option<vk::PFN_vkGetInstanceProcAddr>,
    features2: Option<vk::PFN_vkGetPhysicalDeviceFeatures2>,
    features: Option<vk::PFN_vkGetPhysicalDeviceFeatures>,
    enum_ext: Option<vk::PFN_vkEnumerateDeviceExtensionProperties>,
    /// By physical device.
    enabled: Vec<(u64, Enabled)>,
    /// By device: queue creation flags, and vkGetDeviceQueue2.
    queues: Vec<(u64, u32, vk::PFN_vkGetDeviceQueue2)>,
}

static STATE: Mutex<State> =
    Mutex::new(State { gipa: None, features2: None, features: None, enum_ext: None, enabled: Vec::new(), queues: Vec::new() });

fn state() -> std::sync::MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(|p| p.into_inner())
}

/// What a device has enabled.
struct Enabled {
    core: vk::PhysicalDeviceFeatures,
    /// The VkBool32 fields of each extension feature struct of the creation chain.
    structs: Vec<(vk::StructureType, Vec<vk::Bool32>)>,
    extensions: Vec<CString>,
}

/// Number of VkBool32 fields of the feature structs wgpu-hal 30 queries (all of them are
/// VkBool32s after the header; the count leaves out trailing padding).
fn feature_bool_count(ty: vk::StructureType) -> Option<usize> {
    use vk::StructureType as S;
    Some(match ty {
        S::PHYSICAL_DEVICE_MULTIVIEW_FEATURES => 3,
        S::PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES => 1,
        S::PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES => 20,
        S::PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES => 1,
        S::PHYSICAL_DEVICE_SHADER_ATOMIC_INT64_FEATURES => 2,
        S::PHYSICAL_DEVICE_SHADER_IMAGE_ATOMIC_INT64_FEATURES_EXT => 2,
        S::PHYSICAL_DEVICE_SHADER_ATOMIC_FLOAT_FEATURES_EXT => 12,
        S::PHYSICAL_DEVICE_IMAGE_ROBUSTNESS_FEATURES => 1,
        S::PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT => 3,
        S::PHYSICAL_DEVICE_TEXTURE_COMPRESSION_ASTC_HDR_FEATURES => 1,
        S::PHYSICAL_DEVICE_SHADER_FLOAT16_INT8_FEATURES => 2,
        S::PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES => 4,
        S::PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR => 5,
        S::PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES => 3,
        S::PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR => 1,
        S::PHYSICAL_DEVICE_RAY_TRACING_PIPELINE_FEATURES_KHR => 5,
        S::PHYSICAL_DEVICE_RAY_TRACING_POSITION_FETCH_FEATURES_KHR => 1,
        S::PHYSICAL_DEVICE_MAINTENANCE_4_FEATURES => 1,
        S::PHYSICAL_DEVICE_ZERO_INITIALIZE_WORKGROUP_MEMORY_FEATURES => 1,
        S::PHYSICAL_DEVICE_SUBGROUP_SIZE_CONTROL_FEATURES => 2,
        S::PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT => 5,
        S::PHYSICAL_DEVICE_SHADER_INTEGER_DOT_PRODUCT_FEATURES => 1,
        S::PHYSICAL_DEVICE_FRAGMENT_SHADER_BARYCENTRIC_FEATURES_KHR => 1,
        S::PHYSICAL_DEVICE_PORTABILITY_SUBSET_FEATURES_KHR => 15,
        S::PHYSICAL_DEVICE_COOPERATIVE_MATRIX_FEATURES_KHR => 2,
        S::PHYSICAL_DEVICE_VULKAN_MEMORY_MODEL_FEATURES => 3,
        S::PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES => 1,
        _ => return None,
    })
}

/// The feature structs promoted to Vulkan 1.1-1.3, as FFmpeg enables them through
/// VkPhysicalDeviceVulkan1xFeatures (field lists in the order of the promoted structs).
unsafe fn promoted(p: *const vk::BaseOutStructure) -> Vec<(vk::StructureType, Vec<vk::Bool32>)> {
    use vk::StructureType as S;
    match (*p).s_type {
        S::PHYSICAL_DEVICE_VULKAN_1_1_FEATURES => {
            let f = &*(p as *const vk::PhysicalDeviceVulkan11Features);
            vec![
                (S::PHYSICAL_DEVICE_MULTIVIEW_FEATURES, vec![f.multiview, f.multiview_geometry_shader, f.multiview_tessellation_shader]),
                (S::PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES, vec![f.sampler_ycbcr_conversion]),
                (
                    S::PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES,
                    vec![
                        f.storage_buffer16_bit_access,
                        f.uniform_and_storage_buffer16_bit_access,
                        f.storage_push_constant16,
                        f.storage_input_output16,
                    ],
                ),
                (S::PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES, vec![f.shader_draw_parameters]),
            ]
        }
        S::PHYSICAL_DEVICE_VULKAN_1_2_FEATURES => {
            let f = &*(p as *const vk::PhysicalDeviceVulkan12Features);
            vec![
                (
                    S::PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
                    vec![
                        f.shader_input_attachment_array_dynamic_indexing,
                        f.shader_uniform_texel_buffer_array_dynamic_indexing,
                        f.shader_storage_texel_buffer_array_dynamic_indexing,
                        f.shader_uniform_buffer_array_non_uniform_indexing,
                        f.shader_sampled_image_array_non_uniform_indexing,
                        f.shader_storage_buffer_array_non_uniform_indexing,
                        f.shader_storage_image_array_non_uniform_indexing,
                        f.shader_input_attachment_array_non_uniform_indexing,
                        f.shader_uniform_texel_buffer_array_non_uniform_indexing,
                        f.shader_storage_texel_buffer_array_non_uniform_indexing,
                        f.descriptor_binding_uniform_buffer_update_after_bind,
                        f.descriptor_binding_sampled_image_update_after_bind,
                        f.descriptor_binding_storage_image_update_after_bind,
                        f.descriptor_binding_storage_buffer_update_after_bind,
                        f.descriptor_binding_uniform_texel_buffer_update_after_bind,
                        f.descriptor_binding_storage_texel_buffer_update_after_bind,
                        f.descriptor_binding_update_unused_while_pending,
                        f.descriptor_binding_partially_bound,
                        f.descriptor_binding_variable_descriptor_count,
                        f.runtime_descriptor_array,
                    ],
                ),
                (S::PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES, vec![f.timeline_semaphore]),
                (S::PHYSICAL_DEVICE_SHADER_ATOMIC_INT64_FEATURES, vec![f.shader_buffer_int64_atomics, f.shader_shared_int64_atomics]),
                (S::PHYSICAL_DEVICE_SHADER_FLOAT16_INT8_FEATURES, vec![f.shader_float16, f.shader_int8]),
                (
                    S::PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES,
                    vec![f.buffer_device_address, f.buffer_device_address_capture_replay, f.buffer_device_address_multi_device],
                ),
                (
                    S::PHYSICAL_DEVICE_VULKAN_MEMORY_MODEL_FEATURES,
                    vec![f.vulkan_memory_model, f.vulkan_memory_model_device_scope, f.vulkan_memory_model_availability_visibility_chains],
                ),
            ]
        }
        S::PHYSICAL_DEVICE_VULKAN_1_3_FEATURES => {
            let f = &*(p as *const vk::PhysicalDeviceVulkan13Features);
            vec![
                (S::PHYSICAL_DEVICE_IMAGE_ROBUSTNESS_FEATURES, vec![f.robust_image_access]),
                (S::PHYSICAL_DEVICE_TEXTURE_COMPRESSION_ASTC_HDR_FEATURES, vec![f.texture_compression_astc_hdr]),
                (S::PHYSICAL_DEVICE_MAINTENANCE_4_FEATURES, vec![f.maintenance4]),
                (S::PHYSICAL_DEVICE_ZERO_INITIALIZE_WORKGROUP_MEMORY_FEATURES, vec![f.shader_zero_initialize_workgroup_memory]),
                (S::PHYSICAL_DEVICE_SUBGROUP_SIZE_CONTROL_FEATURES, vec![f.subgroup_size_control, f.compute_full_subgroups]),
                (S::PHYSICAL_DEVICE_SHADER_INTEGER_DOT_PRODUCT_FEATURES, vec![f.shader_integer_dot_product]),
            ]
        }
        _ => Vec::new(),
    }
}

const HEADER: usize = size_of::<vk::BaseOutStructure>();

/// The `count` VkBool32 fields of a feature struct.
unsafe fn bools<'a>(p: *mut vk::BaseOutStructure, count: usize) -> &'a mut [vk::Bool32] {
    std::slice::from_raw_parts_mut((p as *mut u8).add(HEADER) as *mut vk::Bool32, count)
}

unsafe fn core_bools(f: &mut vk::PhysicalDeviceFeatures) -> &mut [vk::Bool32] {
    std::slice::from_raw_parts_mut(f as *mut _ as *mut vk::Bool32, size_of::<vk::PhysicalDeviceFeatures>() / size_of::<vk::Bool32>())
}

impl Enabled {
    unsafe fn read(chain: *const c_void, extensions: &[String]) -> Self {
        let mut core = vk::PhysicalDeviceFeatures::default();
        let mut structs = Vec::new();
        if let Some(f2) = (chain as *const vk::PhysicalDeviceFeatures2).as_ref() {
            core = f2.features;
            let mut p = f2.p_next as *mut vk::BaseOutStructure;
            while let Some(s) = p.as_ref() {
                if let Some(n) = feature_bool_count(s.s_type) {
                    structs.push((s.s_type, bools(p, n).to_vec()));
                }
                structs.extend(promoted(p));
                p = s.p_next;
            }
        }
        let extensions = extensions.iter().filter_map(|e| CString::new(e.as_str()).ok()).collect();
        Enabled { core, structs, extensions }
    }

    /// Masks what the driver reports with what is enabled: extension structs the device
    /// was not created with read as all false; promoted ones take their fields from the
    /// VkPhysicalDeviceVulkan1xFeatures of the creation chain.
    unsafe fn mask(&self, out: &mut vk::PhysicalDeviceFeatures2) {
        self.mask_core(&mut out.features);
        let mut p = out.p_next as *mut vk::BaseOutStructure;
        while let Some(s) = p.as_ref() {
            if let Some(n) = feature_bool_count(s.s_type) {
                let have = self.structs.iter().find(|(t, _)| *t == s.s_type).map(|(_, b)| b.as_slice()).unwrap_or(&[]);
                for (i, b) in bools(p, n).iter_mut().enumerate() {
                    *b &= have.get(i).copied().unwrap_or(0);
                }
            }
            p = s.p_next;
        }
    }

    unsafe fn mask_core(&self, f: &mut vk::PhysicalDeviceFeatures) {
        let mut enabled = self.core;
        for (b, e) in core_bools(f).iter_mut().zip(core_bools(&mut enabled).iter()) {
            *b &= *e;
        }
    }
}

unsafe extern "system" fn hook_features2(phd: vk::PhysicalDevice, out: *mut vk::PhysicalDeviceFeatures2<'_>) {
    let st = state();
    let Some(real) = st.features2 else { return };
    real(phd, out);
    if let (Some((_, en)), Some(out)) = (st.enabled.iter().find(|(d, _)| *d == phd.as_raw()), out.as_mut()) {
        en.mask(out);
    }
}

unsafe extern "system" fn hook_features(phd: vk::PhysicalDevice, out: *mut vk::PhysicalDeviceFeatures) {
    let st = state();
    let Some(real) = st.features else { return };
    real(phd, out);
    if let (Some((_, en)), Some(out)) = (st.enabled.iter().find(|(d, _)| *d == phd.as_raw()), out.as_mut()) {
        en.mask_core(out);
    }
}

unsafe extern "system" fn hook_enum_ext(
    phd: vk::PhysicalDevice,
    layer: *const c_char,
    count: *mut u32,
    props: *mut vk::ExtensionProperties,
) -> vk::Result {
    let st = state();
    let Some(real) = st.enum_ext else { return vk::Result::ERROR_INITIALIZATION_FAILED };
    let en = st.enabled.iter().find(|(d, _)| *d == phd.as_raw());
    let Some((_, en)) = en.filter(|_| layer.is_null()) else { return real(phd, layer, count, props) };
    let mut all = Vec::new();
    loop {
        let mut n = 0;
        let r = real(phd, layer, &mut n, std::ptr::null_mut());
        if r != vk::Result::SUCCESS {
            return r;
        }
        all.resize(n as usize, vk::ExtensionProperties::default());
        match real(phd, layer, &mut n, all.as_mut_ptr()) {
            vk::Result::INCOMPLETE => continue,
            vk::Result::SUCCESS => {
                all.truncate(n as usize);
                break;
            }
            r => return r,
        }
    }
    all.retain(|e| e.extension_name_as_c_str().is_ok_and(|name| en.extensions.iter().any(|x| x.as_c_str() == name)));
    if props.is_null() {
        *count = all.len() as u32;
        return vk::Result::SUCCESS;
    }
    let n = (*count as usize).min(all.len());
    std::ptr::copy_nonoverlapping(all.as_ptr(), props, n);
    *count = n as u32;
    if n < all.len() {
        vk::Result::INCOMPLETE
    } else {
        vk::Result::SUCCESS
    }
}

unsafe extern "system" fn hook_gipa(instance: vk::Instance, name: *const c_char) -> vk::PFN_vkVoidFunction {
    let gipa = state().gipa?;
    let n = CStr::from_ptr(name).to_bytes();
    match n {
        b"vkGetPhysicalDeviceFeatures2" | b"vkGetPhysicalDeviceFeatures2KHR" => {
            return Some(std::mem::transmute::<vk::PFN_vkGetPhysicalDeviceFeatures2, unsafe extern "system" fn()>(hook_features2));
        }
        b"vkGetPhysicalDeviceFeatures" => {
            return Some(std::mem::transmute::<vk::PFN_vkGetPhysicalDeviceFeatures, unsafe extern "system" fn()>(hook_features));
        }
        b"vkEnumerateDeviceExtensionProperties" => {
            return Some(std::mem::transmute::<vk::PFN_vkEnumerateDeviceExtensionProperties, unsafe extern "system" fn()>(hook_enum_ext));
        }
        _ => {}
    }
    let f = gipa(instance, name);
    // wgpu loads VK_KHR_get_physical_device_properties2 entry points, promoted in 1.1:
    // the instance need not have enabled the extension.
    const PROMOTED: [&[u8]; 6] = [
        b"vkGetPhysicalDeviceProperties2KHR",
        b"vkGetPhysicalDeviceFormatProperties2KHR",
        b"vkGetPhysicalDeviceImageFormatProperties2KHR",
        b"vkGetPhysicalDeviceQueueFamilyProperties2KHR",
        b"vkGetPhysicalDeviceMemoryProperties2KHR",
        b"vkGetPhysicalDeviceSparseImageFormatProperties2KHR",
    ];
    if f.is_none() && PROMOTED.contains(&n) {
        if let Ok(core) = CString::new(&n[..n.len() - 3]) {
            return gipa(instance, core.as_ptr());
        }
    }
    f
}

/// vkGetDeviceQueue for queues created with flags, which need vkGetDeviceQueue2.
unsafe extern "system" fn hook_get_device_queue(device: vk::Device, family: u32, index: u32, out: *mut vk::Queue) {
    let Some(&(_, flags, get2)) = state().queues.iter().find(|(d, _, _)| *d == device.as_raw()) else { return };
    let info =
        vk::DeviceQueueInfo2::default().flags(vk::DeviceQueueCreateFlags::from_raw(flags)).queue_family_index(family).queue_index(index);
    get2(device, &info, out);
}

/// Extension names wgpu-hal wants as `&'static CStr`. Leaked once per shared device.
fn static_names(names: &[String]) -> Vec<&'static CStr> {
    names.iter().filter_map(|n| CString::new(n.as_str()).ok()).map(|c| &*Box::leak(c.into_boxed_c_str())).collect()
}

fn gpu_err(e: impl std::fmt::Display) -> Error {
    Error::Gpu(format!("shared Vulkan device: {e}"))
}

impl GpuContext {
    /// A context on a Vulkan device made by the caller, such as FFmpeg's
    /// `AVVulkanDeviceContext`, so frames of that device can be read and written
    /// without copies ([`EffectGraph::process_vulkan`]). Nothing is destroyed with the
    /// context: the device must outlive it.
    ///
    /// # Safety
    /// The handles must be valid, `device` created from `physical_device` with the
    /// listed extensions and features, and the queue unused by others while gpufx
    /// submits (the caller locks it around [`EffectGraph::process_vulkan`]).
    pub unsafe fn from_vulkan(desc: &VulkanDevice) -> Result<Arc<Self>, Error> {
        if desc.get_instance_proc_addr.is_null() || desc.instance.is_null() || desc.physical_device.is_null() || desc.device.is_null() {
            return Err(gpu_err("NULL handle"));
        }
        if desc.api_version < vk::API_VERSION_1_1 {
            return Err(gpu_err("Vulkan 1.1 or later is required"));
        }
        let real: vk::PFN_vkGetInstanceProcAddr = std::mem::transmute(desc.get_instance_proc_addr);
        let instance = vk::Instance::from_raw(desc.instance as u64);
        let phd = vk::PhysicalDevice::from_raw(desc.physical_device as u64);
        let device = vk::Device::from_raw(desc.device as u64);
        let load = |name: &CStr| real(instance, name.as_ptr());
        let (Some(f2), Some(f1), Some(ext), Some(gdpa)) = (
            load(c"vkGetPhysicalDeviceFeatures2"),
            load(c"vkGetPhysicalDeviceFeatures"),
            load(c"vkEnumerateDeviceExtensionProperties"),
            load(c"vkGetDeviceProcAddr"),
        ) else {
            return Err(gpu_err("the instance lacks Vulkan 1.1 entry points"));
        };
        let gdpa: vk::PFN_vkGetDeviceProcAddr = std::mem::transmute(gdpa);
        let get2 = gdpa(device, c"vkGetDeviceQueue2".as_ptr()).ok_or_else(|| gpu_err("no vkGetDeviceQueue2"))?;
        {
            let mut st = state();
            if st.gipa.is_some_and(|g| g as usize != real as usize) {
                return Err(gpu_err("devices of two different Vulkan loaders in one process are not supported"));
            }
            st.gipa = Some(real);
            st.features2 = Some(std::mem::transmute::<unsafe extern "system" fn(), vk::PFN_vkGetPhysicalDeviceFeatures2>(f2));
            st.features = Some(std::mem::transmute::<unsafe extern "system" fn(), vk::PFN_vkGetPhysicalDeviceFeatures>(f1));
            st.enum_ext = Some(std::mem::transmute::<unsafe extern "system" fn(), vk::PFN_vkEnumerateDeviceExtensionProperties>(ext));
            let enabled = Enabled::read(desc.enabled_features, &desc.device_extensions);
            st.enabled.retain(|(d, _)| *d != phd.as_raw());
            st.enabled.push((phd.as_raw(), enabled));
            st.queues.retain(|(d, _, _)| *d != device.as_raw());
            st.queues.push((
                device.as_raw(),
                desc.queue_flags,
                std::mem::transmute::<unsafe extern "system" fn(), vk::PFN_vkGetDeviceQueue2>(get2),
            ));
        }

        let entry = ash::Entry::from_static_fn(ash::StaticFn { get_instance_proc_addr: hook_gipa });
        let ash_instance = ash::Instance::load(entry.static_fn(), instance);
        // wgpu records render passes and graphics barriers: on a compute-only family the
        // driver loses the device (NVIDIA lists one before the graphics family).
        let families = ash_instance.get_physical_device_queue_family_properties(phd);
        let graphics = families
            .get(desc.queue_family as usize)
            .is_some_and(|f| f.queue_flags.contains(vk::QueueFlags::GRAPHICS | vk::QueueFlags::COMPUTE));
        if !graphics {
            return Err(gpu_err(format!("queue family {} has no graphics and compute queue", desc.queue_family)));
        }
        let mut inst_ext = static_names(&desc.instance_extensions);
        if !inst_ext.contains(&ash::khr::get_physical_device_properties2::NAME) {
            inst_ext.push(ash::khr::get_physical_device_properties2::NAME);
        }
        let hal_instance = hal::vulkan::Instance::from_raw(
            entry,
            ash_instance.clone(),
            desc.api_version,
            0,
            None,
            inst_ext,
            wgpu::InstanceFlags::empty(),
            Default::default(),
            false,
            Some(Box::new(|| ())),
        )
        .map_err(gpu_err)?;
        let exposed = hal_instance.expose_adapter(phd).ok_or_else(|| gpu_err("wgpu cannot use this physical device"))?;
        let features = exposed.features & crate::profile::features();
        let limits = device_limits(&exposed.capabilities.limits);
        let flags = desc.queue_flags;
        let ash_device = ash::Device::load_with(
            |name| {
                if flags != 0 && name == c"vkGetDeviceQueue" {
                    hook_get_device_queue as *const c_void
                } else {
                    gdpa(device, name.as_ptr()).map_or(std::ptr::null(), |f| f as *const c_void)
                }
            },
            device,
        );
        let dev_ext = static_names(&desc.device_extensions);
        let open = exposed
            .adapter
            .device_from_raw(
                ash_device,
                Some(Box::new(|| ())),
                &dev_ext,
                features,
                &limits,
                &wgpu::MemoryHints::Performance,
                desc.queue_family,
                desc.queue_index,
            )
            .map_err(gpu_err)?;
        let wgpu_instance = wgpu::Instance::from_hal::<Vulkan>(hal_instance);
        let adapter = wgpu_instance.create_adapter_from_hal(exposed);
        let (device, queue) = adapter
            .create_device_from_hal(
                open,
                &wgpu::DeviceDescriptor {
                    label: Some("gpufx (shared Vulkan device)"),
                    required_features: features,
                    required_limits: limits,
                    ..Default::default()
                },
            )
            .map_err(gpu_err)?;
        let mut ctx = GpuContext::from_device(device, queue, adapter.get_info(), None);
        Arc::get_mut(&mut ctx).expect("new").vulkan_queue_family = Some(desc.queue_family);
        Ok(ctx)
    }
}

/// wgpu state matching a layout, or `None` when wgpu has no state for it.
fn state_of(layout: vk::ImageLayout) -> Option<wgpu::TextureUses> {
    use wgpu::TextureUses as U;
    Some(match layout {
        vk::ImageLayout::UNDEFINED => U::UNINITIALIZED,
        vk::ImageLayout::GENERAL => U::STORAGE_READ_WRITE,
        vk::ImageLayout::SHADER_READ_ONLY_OPTIMAL => U::RESOURCE,
        vk::ImageLayout::TRANSFER_SRC_OPTIMAL => U::COPY_SRC,
        vk::ImageLayout::TRANSFER_DST_OPTIMAL => U::COPY_DST,
        vk::ImageLayout::COLOR_ATTACHMENT_OPTIMAL => U::COLOR_TARGET,
        _ => return None,
    })
}

impl EffectGraph {
    /// Runs the graph on Vulkan frames of the device the graph's context shares
    /// ([`GpuContext::from_vulkan`]), without copying them: each plane image is read or
    /// written in place. The submission waits on every image's semaphore at its value and
    /// signals one more; `value` and `layout` of every plane are updated to what the next
    /// user must wait for and find. Returns once the work is submitted, not done.
    /// Without `info` the effects are bypassed ([`EffectGraph::convert`]).
    ///
    /// # Safety
    /// The images must be valid images of that device as described (one per plane, with
    /// `SAMPLED` usage for inputs and `STORAGE` for outputs), and the caller must hold
    /// the frames (FFmpeg's `lock_frame`) and the queue while this runs.
    pub unsafe fn process_vulkan(
        &mut self,
        inputs: &mut [VulkanFrame],
        outs: &mut [VulkanFrame],
        info: Option<&FrameInfo>,
    ) -> Result<(), Error> {
        let t_start = std::time::Instant::now();
        let ctx = self.context().clone();
        if *ctx.vulkan_submit.lock().unwrap_or_else(|p| p.into_inner()) {
            return Err(Error::Gpu("an earlier Vulkan submission failed; the shared device is no longer used".into()));
        }
        let scope = ctx.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let family =
            ctx.vulkan_queue_family.ok_or_else(|| Error::Gpu("Vulkan frames need a graph opened on a shared Vulkan device".into()))?;
        let device = &ctx.device;

        // Wrap every image (no copy, nothing owned) and note those wgpu cannot take as
        // they are: their layout has no wgpu state, a raw barrier moves them to GENERAL.
        struct Wrapped {
            frames: Vec<GpuFrame>,
            textures: Vec<wgpu::Texture>,
        }
        let mut barriers: Vec<vk::ImageMemoryBarrier> = Vec::new();
        let (ins, outs_w, raw_device) = {
            let hal_device = device.as_hal::<Vulkan>().ok_or_else(|| Error::Gpu("the device is not a Vulkan device".into()))?;
            let raw_device = hal_device.raw_device().clone();
            let mut hal_textures = Vec::new();
            for (output, list) in [(false, &*inputs), (true, &*outs)] {
                for (n, f) in list.iter().enumerate() {
                    let what = format!("{} {n}", if output { "output" } else { "input" });
                    let count = f.format.plane_count();
                    if f.planes.len() != count {
                        return Err(Error::Frame(format!(
                            "{what}: a {} frame needs one Vulkan image per plane ({count}), got {}; multiplane images are not \
                             supported (FFmpeg: create the device with disable_multiplane=1)",
                            f.format.name(),
                            f.planes.len()
                        )));
                    }
                    for (p, plane) in f.planes.iter().enumerate() {
                        let format = f.format.plane_texture_format(p);
                        if plane.format != vk_format(format).as_raw() {
                            return Err(Error::Frame(format!(
                                "{what}: plane {p} of a {} frame must be {:?}, the image is VkFormat {}",
                                f.format.name(),
                                vk_format(format),
                                plane.format
                            )));
                        }
                        if plane.queue_family != vk::QUEUE_FAMILY_IGNORED && plane.queue_family != family {
                            return Err(Error::Frame(format!(
                                "{what}: plane {p} belongs to queue family {}, gpufx submits to {family}",
                                plane.queue_family
                            )));
                        }
                        let (w, h) = f.format.plane_texture_size(p, f.width, f.height);
                        let usage = if output { wgpu::TextureUses::STORAGE_WRITE_ONLY } else { wgpu::TextureUses::RESOURCE };
                        let hal_desc = hal::TextureDescriptor {
                            label: Some("gpufx vulkan plane"),
                            size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
                            mip_level_count: 1,
                            sample_count: 1,
                            dimension: wgpu::TextureDimension::D2,
                            format,
                            usage,
                            memory_flags: hal::MemoryFlags::empty(),
                            view_formats: Vec::new(),
                        };
                        let image = vk::Image::from_raw(plane.image);
                        let layout = vk::ImageLayout::from_raw(plane.layout);
                        let initial = if output {
                            // Written whole: the old content may go.
                            wgpu::TextureUses::UNINITIALIZED
                        } else if let Some(s) = state_of(layout) {
                            s
                        } else {
                            barriers.push(
                                vk::ImageMemoryBarrier::default()
                                    .src_access_mask(vk::AccessFlags::MEMORY_WRITE)
                                    .dst_access_mask(vk::AccessFlags::MEMORY_READ | vk::AccessFlags::MEMORY_WRITE)
                                    .old_layout(layout)
                                    .new_layout(vk::ImageLayout::GENERAL)
                                    .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                                    .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                                    .image(image)
                                    .subresource_range(vk::ImageSubresourceRange {
                                        aspect_mask: vk::ImageAspectFlags::COLOR,
                                        base_mip_level: 0,
                                        level_count: 1,
                                        base_array_layer: 0,
                                        layer_count: 1,
                                    }),
                            );
                            wgpu::TextureUses::STORAGE_READ_WRITE
                        };
                        let tex =
                            hal_device.texture_from_raw(image, &hal_desc, Some(Box::new(|| ())), hal::vulkan::TextureMemory::External);
                        hal_textures.push((output, n, tex, format, (w, h), initial));
                    }
                }
            }
            drop(hal_device);
            let mut ins = Wrapped { frames: Vec::new(), textures: Vec::new() };
            let mut outs_w = Wrapped { frames: Vec::new(), textures: Vec::new() };
            for f in inputs.iter() {
                ins.frames.push(GpuFrame { format: f.format, width: f.width, height: f.height, planes: Vec::new(), color: f.color });
            }
            for f in outs.iter() {
                outs_w.frames.push(GpuFrame { format: f.format, width: f.width, height: f.height, planes: Vec::new(), color: f.color });
            }
            for (output, n, tex, format, (w, h), initial) in hal_textures {
                let usage = if output { wgpu::TextureUsages::STORAGE_BINDING } else { wgpu::TextureUsages::TEXTURE_BINDING };
                let t = device.create_texture_from_hal::<Vulkan>(
                    tex,
                    &wgpu::TextureDescriptor {
                        label: Some("gpufx vulkan plane"),
                        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
                        mip_level_count: 1,
                        sample_count: 1,
                        dimension: wgpu::TextureDimension::D2,
                        format,
                        usage,
                        view_formats: &[],
                    },
                    initial,
                );
                let w = if output { &mut outs_w } else { &mut ins };
                w.frames[n].planes.push(t.clone());
                w.textures.push(t);
            }
            (ins, outs_w, raw_device)
        };

        let t_import = t_start.elapsed();
        let mut buffers = Vec::new();
        if !barriers.is_empty() {
            let mut pre = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("gpufx vulkan layouts") });
            pre.as_hal_mut::<Vulkan, _, _>(|enc| {
                if let Some(enc) = enc {
                    raw_device.cmd_pipeline_barrier(
                        enc.raw_handle(),
                        vk::PipelineStageFlags::ALL_COMMANDS,
                        vk::PipelineStageFlags::ALL_COMMANDS,
                        vk::DependencyFlags::empty(),
                        &[],
                        &[],
                        &barriers,
                    );
                }
            });
            buffers.push(pre.finish());
        }
        let mut enc = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("gpufx vulkan") });
        self.allow_direct_gpu();
        self.encode_gpu(&ins.frames, &outs_w.frames, info, &mut enc)?;
        // Leave every image in one known layout for whoever uses it next.
        enc.transition_resources(
            std::iter::empty(),
            ins.textures.iter().chain(&outs_w.textures).map(|t| wgpu::TextureTransition {
                texture: t,
                selector: None,
                state: wgpu::TextureUses::STORAGE_READ_WRITE,
            }),
        );
        buffers.push(enc.finish());

        // Wait for each semaphore once, at the highest value asked, and signal one more.
        let mut sems: Vec<(u64, u64)> = Vec::new();
        for plane in inputs.iter().chain(outs.iter()).flat_map(|f| &f.planes) {
            match sems.iter_mut().find(|(s, _)| *s == plane.semaphore) {
                Some((_, v)) => *v = (*v).max(plane.value),
                None => sems.push((plane.semaphore, plane.value)),
            }
        }
        // Held from staging the semaphores until the submission took them, so two threads
        // using this device never stage into each other's submission.
        let t_submit = std::time::Instant::now();
        let mut poisoned = ctx.vulkan_submit.lock().unwrap_or_else(|p| p.into_inner());
        if *poisoned {
            return Err(Error::Gpu("an earlier Vulkan submission failed; the shared device is no longer used".into()));
        }
        {
            let queue = ctx.queue.as_hal::<Vulkan>().ok_or_else(|| Error::Gpu("the queue is not a Vulkan queue".into()))?;
            for &(s, v) in &sems {
                let sem = vk::Semaphore::from_raw(s);
                queue.add_wait_semaphore(sem, Some(v), vk::PipelineStageFlags::ALL_COMMANDS);
                queue.add_signal_semaphore(sem, Some(v + 1));
            }
        }
        ctx.queue.submit(buffers);
        self.release_frame();
        // A submission wgpu refused leaves the semaphores staged: take them back so no
        // later submission signals stale values, and stop using the device.
        let mut left = false;
        {
            let queue = ctx.queue.as_hal::<Vulkan>().ok_or_else(|| Error::Gpu("the queue is not a Vulkan queue".into()))?;
            for &(s, _) in &sems {
                let sem = vk::Semaphore::from_raw(s);
                left |= queue.remove_wait_semaphore(sem);
                left |= queue.remove_signal_semaphore(sem);
            }
        }
        let t_scope = std::time::Instant::now();
        let error = pollster::block_on(scope.pop());
        if left || error.is_some() {
            *poisoned = true;
            let why = error.map_or_else(|| "it was not submitted".to_string(), |e| e.to_string());
            return Err(Error::Gpu(format!("Vulkan submission failed ({why}); the shared device is no longer used")));
        }
        drop(poisoned);
        for plane in inputs.iter_mut().chain(outs.iter_mut()).flat_map(|f| f.planes.iter_mut()) {
            plane.layout = LAYOUT_AFTER;
            plane.value = sems.iter().find(|(s, _)| *s == plane.semaphore).map_or(plane.value, |&(_, v)| v + 1);
        }
        if crate::profile::enabled() {
            use crate::profile::Cpu;
            self.profile_cpu(Cpu::Import, t_import);
            self.profile_cpu(Cpu::Submit, t_scope - t_submit);
            self.profile_cpu(Cpu::Scope, t_scope.elapsed());
            self.profile_cpu(Cpu::Total, t_start.elapsed());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// FFmpeg enables promoted features through VkPhysicalDeviceVulkan1xFeatures; wgpu asks
    /// for the promoted structs: the fields must land in the right places.
    #[test]
    fn promoted_features_are_projected() {
        let mut v12 = vk::PhysicalDeviceVulkan12Features::default().timeline_semaphore(true).runtime_descriptor_array(true);
        let mut v13 = vk::PhysicalDeviceVulkan13Features::default().shader_zero_initialize_workgroup_memory(true);
        let enabled_core = vk::PhysicalDeviceFeatures::default().shader_int16(true);
        let chain = vk::PhysicalDeviceFeatures2::default().features(enabled_core).push_next(&mut v12).push_next(&mut v13);
        let en = unsafe { Enabled::read(&chain as *const _ as *const c_void, &[]) };

        // What a driver supporting everything reports.
        let mut timeline = vk::PhysicalDeviceTimelineSemaphoreFeatures::default().timeline_semaphore(true);
        let mut indexing =
            vk::PhysicalDeviceDescriptorIndexingFeatures::default().runtime_descriptor_array(true).descriptor_binding_partially_bound(true);
        let mut zero = vk::PhysicalDeviceZeroInitializeWorkgroupMemoryFeatures::default().shader_zero_initialize_workgroup_memory(true);
        let mut robust = vk::PhysicalDeviceRobustness2FeaturesEXT::default().robust_buffer_access2(true);
        let all = vk::PhysicalDeviceFeatures::default().shader_int16(true).robust_buffer_access(true);
        let mut out = vk::PhysicalDeviceFeatures2::default()
            .features(all)
            .push_next(&mut timeline)
            .push_next(&mut indexing)
            .push_next(&mut zero)
            .push_next(&mut robust);
        unsafe { en.mask(&mut out) };
        assert_eq!(out.features.shader_int16, 1);
        assert_eq!(out.features.robust_buffer_access, 0, "not enabled by FFmpeg");
        assert_eq!(timeline.timeline_semaphore, 1);
        assert_eq!(indexing.runtime_descriptor_array, 1);
        assert_eq!(indexing.descriptor_binding_partially_bound, 0);
        assert_eq!(zero.shader_zero_initialize_workgroup_memory, 1);
        assert_eq!(robust.robust_buffer_access2, 0, "extension struct absent from the chain");
    }

    /// The bool count of every struct matches ash's layout (no trailing padding read).
    #[test]
    fn bool_counts_fit_the_structs() {
        use vk::StructureType as S;
        for (ty, size) in [
            (S::PHYSICAL_DEVICE_MULTIVIEW_FEATURES, size_of::<vk::PhysicalDeviceMultiviewFeatures>()),
            (S::PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES, size_of::<vk::PhysicalDeviceDescriptorIndexingFeatures>()),
            (S::PHYSICAL_DEVICE_SHADER_ATOMIC_FLOAT_FEATURES_EXT, size_of::<vk::PhysicalDeviceShaderAtomicFloatFeaturesEXT>()),
            (S::PHYSICAL_DEVICE_PORTABILITY_SUBSET_FEATURES_KHR, size_of::<vk::PhysicalDevicePortabilitySubsetFeaturesKHR>()),
        ] {
            let n = feature_bool_count(ty).unwrap();
            assert!(HEADER + n * 4 <= size && size - (HEADER + n * 4) < 8, "{ty:?}");
        }
    }
}
