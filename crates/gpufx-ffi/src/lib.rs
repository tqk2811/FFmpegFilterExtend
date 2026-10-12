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
use std::ptr;
use std::sync::{Arc, Mutex, OnceLock, Weak};

use gpufx_core::{Backend, Effect, GpuContext, Image, Package, StreamInfo};

/// Bumped when the C ABI changes incompatibly. Must match `GPUFX_API_VERSION` in gpufx.h.
const API_VERSION: u32 = 2;

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

pub struct GpufxEffect {
    effect: Effect,
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

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_open(path: *const c_char, backend: *const c_char) -> *mut GpufxEffect {
    guard(ptr::null_mut(), || {
        let path = str_arg(path, "path")?;
        let backend: Backend = if backend.is_null() {
            Backend::Auto
        } else {
            str_arg(backend, "backend")?.parse().map_err(|e: gpufx_core::Error| e.to_string())?
        };
        let package = Package::open(path).map_err(|e| format!("{path}: {e}"))?;
        let ctx = context(backend).map_err(|e| e.to_string())?;
        let device = cstring(&ctx.description());
        let effect = Effect::new(ctx, package).map_err(|e| format!("{path}: {e}"))?;
        let m = &effect.package().manifest;
        let out = GpufxEffect {
            name: cstring(&m.name),
            device,
            inputs: m.inputs.iter().map(|i| cstring(&i.name)).collect(),
            input_formats: m.inputs.iter().map(|i| i.formats.iter().map(|f| cstring(f)).collect()).collect(),
            output_formats: m.output.formats.iter().map(|f| cstring(f)).collect(),
            params: m.params.iter().map(|p| cstring(&p.name)).collect(),
            effect,
        };
        Ok(Box::into_raw(Box::new(out)))
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
        fx.effect.package().manifest.check_inputs(&infos).map_err(|e| e.to_string())?;
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
pub unsafe extern "C" fn gpufx_effect_set_param(fx: *mut GpufxEffect, name: *const c_char, value: *const c_char) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        let (name, value) = (str_arg(name, "name")?, str_arg(value, "value")?);
        fx.effect.params_mut().set_str(name, value).map_err(|e| e.to_string())?;
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
        fx.effect.params_mut().set(name, values).map_err(|e| e.to_string())?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_process(
    fx: *mut GpufxEffect,
    inputs: *const GpufxImage,
    nb_inputs: u32,
    out: *mut u8,
    out_stride: u32,
    time: f64,
    frame: u64,
) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        if inputs.is_null() || out.is_null() || nb_inputs == 0 {
            return Err("inputs and out must not be NULL".into());
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
        let (w, h) = (images[0].width as usize, images[0].height as usize);
        let out_len = (h - 1) * out_stride as usize + w * 4;
        let out = std::slice::from_raw_parts_mut(out, out_len);
        fx.effect.process(&images, out, out_stride, time, frame).map_err(|e| e.to_string())?;
        Ok(0)
    })
}
