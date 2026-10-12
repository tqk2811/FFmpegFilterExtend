//! C ABI of gpufx. See `include/gpufx.h` for the documented interface.
//!
//! Every function returning `int` returns 0 on success and a negative value on error;
//! functions returning pointers return NULL on error. `gpufx_last_error()` then describes
//! the failure for the calling thread.

#![allow(clippy::missing_safety_doc)]

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_char, c_int, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use gpufx_core::{Backend, Effect, EffectChain, FrameInfo, GpuContext, Image, ImageMut, Package, Program, StreamInfo};

/// Bumped when the C ABI changes incompatibly. Must match `GPUFX_API_VERSION` in gpufx.h.
const API_VERSION: u32 = 3;

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

fn set_error(msg: impl Into<String>) {
    let msg = CString::new(msg.into().replace('\0', " ")).unwrap_or_default();
    LAST_ERROR.with(|e| *e.borrow_mut() = msg);
}

/// Runs `f`, converting errors and panics into the C error convention.
fn guard<T>(fallback: T, f: impl FnOnce() -> Result<T, String>) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => {
            set_error(e);
            fallback
        }
        Err(_) => {
            set_error("internal panic in gpufx");
            fallback
        }
    }
}

unsafe fn str_arg<'a>(p: *const c_char, what: &str) -> Result<&'a str, String> {
    if p.is_null() {
        return Err(format!("{what} is NULL"));
    }
    CStr::from_ptr(p).to_str().map_err(|_| format!("{what} is not UTF-8"))
}

/// GPU devices are shared by every effect opened with the same backend.
fn context(backend: Backend) -> Result<Arc<GpuContext>, gpufx_core::Error> {
    static CACHE: OnceLock<Mutex<HashMap<String, Weak<GpuContext>>>> = OnceLock::new();
    let mut cache = CACHE.get_or_init(Default::default).lock().unwrap_or_else(|p| p.into_inner());
    let key = format!("{backend:?}");
    if let Some(ctx) = cache.get(&key).and_then(Weak::upgrade) {
        return Ok(ctx);
    }
    let ctx = GpuContext::new(backend)?;
    cache.insert(key, Arc::downgrade(&ctx));
    Ok(ctx)
}

/// Packages read and compiled so far; lets tests check that the cache works.
static PROGRAM_LOADS: AtomicUsize = AtomicUsize::new(0);

type ProgramCache = Mutex<Vec<(PathBuf, Weak<Program>)>>;

/// Compiled packages are shared by every effect opened from the same file on the same
/// device, for as long as one of them is alive. The file is read once: changes made to
/// it while an effect using it is open are not picked up.
fn program(path: &str, ctx: Arc<GpuContext>) -> Result<Arc<Program>, String> {
    static CACHE: OnceLock<ProgramCache> = OnceLock::new();
    // canonicalize fails on some Windows volumes (RAM disks, virtual drives) that open
    // fine; the key is then only as good as the absolute path.
    let canonical = std::fs::canonicalize(path).or_else(|_| std::path::absolute(path)).map_err(|e| format!("{path}: {e}"))?;
    // Held while loading so two filters opening the same package load it only once.
    let mut cache = CACHE.get_or_init(Default::default).lock().unwrap_or_else(|p| p.into_inner());
    cache.retain(|(_, weak)| weak.strong_count() > 0);
    let hit =
        cache.iter().filter(|(p, _)| *p == canonical).filter_map(|(_, weak)| weak.upgrade()).find(|prog| Arc::ptr_eq(prog.context(), &ctx));
    if let Some(prog) = hit {
        return Ok(prog);
    }
    let package = Package::open(&canonical).map_err(|e| format!("{path}: {e}"))?;
    let prog = Program::new(ctx, package).map_err(|e| format!("{path}: {e}"))?;
    PROGRAM_LOADS.fetch_add(1, Ordering::Relaxed);
    cache.push((canonical, Arc::downgrade(&prog)));
    Ok(prog)
}

pub struct GpufxEffect {
    chain: EffectChain,
    name: CString,
    device: CString,
    inputs: Vec<CString>,
    input_formats: Vec<Vec<CString>>,
    output_formats: Vec<CString>,
    params: Vec<CString>,
}

#[repr(C)]
pub struct GpufxImage {
    pub data: *const u8,
    pub width: u32,
    pub height: u32,
    pub stride: u32,
}

#[repr(C)]
pub struct GpufxOutput {
    pub data: *mut u8,
    pub width: u32,
    pub height: u32,
    pub stride: u32,
}

#[repr(C)]
pub struct GpufxFrameInfo {
    pub time: f64,
    pub frame: u64,
    pub pixel_aspect: f64,
}

#[repr(C)]
pub struct GpufxStreamInfo {
    pub format: *const c_char,
    pub width: u32,
    pub height: u32,
}

fn cstring(s: &str) -> CString {
    CString::new(s.replace('\0', " ")).unwrap_or_default()
}

#[no_mangle]
pub extern "C" fn gpufx_version() -> u32 {
    API_VERSION
}

#[no_mangle]
pub extern "C" fn gpufx_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

/// Label of a package in parameter names: its file name without `.zip`.
fn label(path: &str) -> String {
    let p = std::path::Path::new(path);
    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| path.to_string());
    name.strip_suffix(".zip").or_else(|| name.strip_suffix(".ZIP")).unwrap_or(&name).to_string()
}

unsafe fn open_chain(paths: &[&str], backend: *const c_char) -> Result<*mut GpufxEffect, String> {
    let backend: Backend = if backend.is_null() {
        Backend::Auto
    } else {
        str_arg(backend, "backend")?.parse().map_err(|e: gpufx_core::Error| e.to_string())?
    };
    let ctx = context(backend).map_err(|e| e.to_string())?;
    let device = cstring(&ctx.description());
    let mut effects = Vec::with_capacity(paths.len());
    for path in paths {
        let effect = Effect::from_program(program(path, ctx.clone())?).map_err(|e| format!("{path}: {e}"))?;
        effects.push((label(path), effect));
    }
    let chain = EffectChain::new(effects).map_err(|e| e.to_string())?;
    let first = &chain.first().package().manifest;
    let names: Vec<&str> = chain.effects().iter().map(|fx| fx.package().manifest.name.as_str()).collect();
    let out = GpufxEffect {
        name: cstring(&names.join(" | ")),
        device,
        inputs: first.inputs.iter().map(|i| cstring(&i.name)).collect(),
        input_formats: first.inputs.iter().map(|i| i.formats.iter().map(|f| cstring(f)).collect()).collect(),
        output_formats: chain.last().package().manifest.output.formats.iter().map(|f| cstring(f)).collect(),
        params: chain.param_names().iter().map(|p| cstring(p)).collect(),
        chain,
    };
    Ok(Box::into_raw(Box::new(out)))
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_open(path: *const c_char, backend: *const c_char) -> *mut GpufxEffect {
    guard(ptr::null_mut(), || open_chain(&[str_arg(path, "path")?], backend))
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_open_chain(paths: *const *const c_char, count: u32, backend: *const c_char) -> *mut GpufxEffect {
    guard(ptr::null_mut(), || {
        if paths.is_null() || count == 0 {
            return Err("paths must hold at least one path".into());
        }
        let raw = std::slice::from_raw_parts(paths, count as usize);
        let mut list = Vec::with_capacity(raw.len());
        for (i, &p) in raw.iter().enumerate() {
            list.push(str_arg(p, &format!("path {i}"))?);
        }
        open_chain(&list, backend)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_free(fx: *mut GpufxEffect) {
    if !fx.is_null() {
        drop(Box::from_raw(fx));
    }
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_name(fx: *const GpufxEffect) -> *const c_char {
    fx.as_ref().map_or(ptr::null(), |fx| fx.name.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_device(fx: *const GpufxEffect) -> *const c_char {
    fx.as_ref().map_or(ptr::null(), |fx| fx.device.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_input_count(fx: *const GpufxEffect) -> u32 {
    fx.as_ref().map_or(0, |fx| fx.inputs.len() as u32)
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_input_name(fx: *const GpufxEffect, index: u32) -> *const c_char {
    fx.as_ref().and_then(|fx| fx.inputs.get(index as usize)).map_or(ptr::null(), |s| s.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_input_format_count(fx: *const GpufxEffect, input: u32) -> u32 {
    fx.as_ref().and_then(|fx| fx.input_formats.get(input as usize)).map_or(0, |f| f.len() as u32)
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_input_format(fx: *const GpufxEffect, input: u32, index: u32) -> *const c_char {
    fx.as_ref().and_then(|fx| fx.input_formats.get(input as usize)).and_then(|f| f.get(index as usize)).map_or(ptr::null(), |s| s.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_output_format_count(fx: *const GpufxEffect) -> u32 {
    fx.as_ref().map_or(0, |fx| fx.output_formats.len() as u32)
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_output_format(fx: *const GpufxEffect, index: u32) -> *const c_char {
    fx.as_ref().and_then(|fx| fx.output_formats.get(index as usize)).map_or(ptr::null(), |s| s.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_check_inputs(fx: *const GpufxEffect, streams: *const GpufxStreamInfo, count: u32) -> c_int {
    guard(-1, || {
        let fx = fx.as_ref().ok_or("effect is NULL")?;
        if streams.is_null() || count == 0 {
            return Err("streams must not be NULL".into());
        }
        let raw = std::slice::from_raw_parts(streams, count as usize);
        let mut infos = Vec::with_capacity(raw.len());
        for (i, s) in raw.iter().enumerate() {
            let format = if s.format.is_null() { None } else { Some(str_arg(s.format, &format!("stream {i} format"))?) };
            infos.push(StreamInfo { format, width: s.width, height: s.height });
        }
        fx.chain.check_inputs(&infos).map_err(|e| e.to_string())?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_param_count(fx: *const GpufxEffect) -> u32 {
    fx.as_ref().map_or(0, |fx| fx.params.len() as u32)
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_param_name(fx: *const GpufxEffect, index: u32) -> *const c_char {
    fx.as_ref().and_then(|fx| fx.params.get(index as usize)).map_or(ptr::null(), |s| s.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_find_param(fx: *const GpufxEffect, name: *const c_char) -> c_int {
    guard(-1, || {
        let fx = fx.as_ref().ok_or("effect is NULL")?;
        let i = fx.chain.find_param(str_arg(name, "name")?).map_err(|e| e.to_string())?;
        Ok(i as c_int)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_set_param(fx: *mut GpufxEffect, name: *const c_char, value: *const c_char) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        let (name, value) = (str_arg(name, "name")?, str_arg(value, "value")?);
        fx.chain.set_param_str(name, value).map_err(|e| e.to_string())?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_set_param_values(fx: *mut GpufxEffect, name: *const c_char, values: *const f64, count: u32) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        let name = str_arg(name, "name")?;
        if values.is_null() || count == 0 || count > 4 {
            return Err("values must hold 1 to 4 numbers".into());
        }
        let values = std::slice::from_raw_parts(values, count as usize);
        fx.chain.set_param(name, values).map_err(|e| e.to_string())?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_process(
    fx: *mut GpufxEffect,
    inputs: *const GpufxImage,
    nb_inputs: u32,
    out: *const GpufxOutput,
    info: *const GpufxFrameInfo,
) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        let (out, info) = (out.as_ref().ok_or("out is NULL")?, info.as_ref().ok_or("info is NULL")?);
        if inputs.is_null() || nb_inputs == 0 || out.data.is_null() {
            return Err("inputs and out must not be NULL".into());
        }
        if out.height == 0 {
            return Err("out has no rows".into());
        }
        let raw = std::slice::from_raw_parts(inputs, nb_inputs as usize);
        let mut images = Vec::with_capacity(raw.len());
        for (i, img) in raw.iter().enumerate() {
            if img.data.is_null() || img.height == 0 {
                return Err(format!("input {i} has no data"));
            }
            let len = (img.height as usize - 1) * img.stride as usize + img.width as usize * 4;
            images.push(Image {
                data: std::slice::from_raw_parts(img.data, len),
                width: img.width,
                height: img.height,
                stride: img.stride,
            });
        }
        let out_len = (out.height as usize - 1) * out.stride as usize + out.width as usize * 4;
        let target =
            ImageMut { data: std::slice::from_raw_parts_mut(out.data, out_len), width: out.width, height: out.height, stride: out.stride };
        let info = FrameInfo { time: info.time, frame: info.frame, pixel_aspect: info.pixel_aspect };
        fx.chain.process(&images, target, &info).map_err(|e| e.to_string())?;
        Ok(0)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open(path: &std::path::Path) -> *mut GpufxEffect {
        let path = CString::new(path.to_str().unwrap()).unwrap();
        unsafe { gpufx_effect_open(path.as_ptr(), ptr::null()) }
    }

    /// Tests that open effects take this lock: the load counter is process-wide, so the
    /// exact counts of the cache test would be racy otherwise.
    static SERIAL: Mutex<()> = Mutex::new(());

    fn serial() -> std::sync::MutexGuard<'static, ()> {
        SERIAL.lock().unwrap_or_else(|p| p.into_inner())
    }

    #[test]
    fn a_package_is_loaded_once_while_it_is_in_use() {
        let _serial = serial();
        if GpuContext::new(Backend::Auto).is_err() {
            eprintln!("skipping: no GPU adapter");
            return;
        }
        let examples = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/effects");
        let invert = examples.join("invert");
        // The same package through another spelling of its path.
        let invert_again = examples.join("../effects/./invert");
        let loads = || PROGRAM_LOADS.load(Ordering::Relaxed);

        let start = loads();
        let a = open(&invert);
        assert!(!a.is_null(), "{:?}", unsafe { CStr::from_ptr(gpufx_last_error()) });
        let b = open(&invert_again);
        assert!(!b.is_null());
        assert_eq!(loads(), start + 1, "second open must reuse the compiled package");

        // Parameters stay per effect.
        let (name, value) = (CString::new("amount").unwrap(), CString::new("0.25").unwrap());
        assert_eq!(unsafe { gpufx_effect_set_param(a, name.as_ptr(), value.as_ptr()) }, 0);
        let (pa, pb) = unsafe { ((*a).chain.first().params().bytes(), (*b).chain.first().params().bytes()) };
        assert_ne!(pa, pb);

        let other = open(&examples.join("vignette"));
        assert!(!other.is_null());
        assert_eq!(loads(), start + 2);

        unsafe {
            gpufx_effect_free(a);
            gpufx_effect_free(b);
            gpufx_effect_free(other);
        }
        // Nothing holds the package any more, so it is read again.
        let c = open(&invert);
        assert!(!c.is_null());
        assert_eq!(loads(), start + 3);
        unsafe { gpufx_effect_free(c) };
    }

    #[test]
    fn a_chain_lists_and_finds_qualified_parameters() {
        let _serial = serial();
        if GpuContext::new(Backend::Auto).is_err() {
            eprintln!("skipping: no GPU adapter");
            return;
        }
        let examples = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/effects");
        let paths: Vec<CString> =
            ["invert", "vignette"].iter().map(|n| CString::new(examples.join(n).to_str().unwrap()).unwrap()).collect();
        let ptrs: Vec<*const c_char> = paths.iter().map(|p| p.as_ptr()).collect();
        let fx = unsafe { gpufx_effect_open_chain(ptrs.as_ptr(), 2, ptr::null()) };
        assert!(!fx.is_null(), "{:?}", unsafe { CStr::from_ptr(gpufx_last_error()) });
        let name = |i| unsafe { CStr::from_ptr(gpufx_effect_param_name(fx, i)) }.to_str().unwrap().to_string();
        let find = |n: &str| unsafe { gpufx_effect_find_param(fx, CString::new(n).unwrap().as_ptr()) };
        assert_eq!(name(0), "invert.amount");
        assert_eq!(name(find("strength") as u32), "vignette.strength");
        assert_eq!(find("1.strength"), find("strength"));
        assert!(find("nothing") < 0);
        assert!(unsafe { CStr::from_ptr(gpufx_last_error()) }.to_str().unwrap().contains("nothing"));
        assert_eq!(unsafe { CStr::from_ptr(gpufx_effect_name(fx)) }.to_str().unwrap(), "Invert | Vignette");

        let src = [200u8; 4 * 4 * 4];
        let mut out = vec![0u8; src.len()];
        let input = GpufxImage { data: src.as_ptr(), width: 4, height: 4, stride: 16 };
        let target = GpufxOutput { data: out.as_mut_ptr(), width: 4, height: 4, stride: 16 };
        let info = GpufxFrameInfo { time: 0.0, frame: 0, pixel_aspect: 1.0 };
        let v = CString::new("0").unwrap();
        assert_eq!(unsafe { gpufx_effect_set_param(fx, CString::new("strength").unwrap().as_ptr(), v.as_ptr()) }, 0);
        assert_eq!(unsafe { gpufx_effect_process(fx, &input, 1, &target, &info) }, 0);
        assert_eq!(out[..4], [55, 55, 55, 200]);
        // An output of another size is refused instead of overflowing.
        let small = GpufxOutput { data: out.as_mut_ptr(), width: 2, height: 2, stride: 8 };
        assert!(unsafe { gpufx_effect_process(fx, &input, 1, &small, &info) } < 0);
        unsafe { gpufx_effect_free(fx) };
    }
}
