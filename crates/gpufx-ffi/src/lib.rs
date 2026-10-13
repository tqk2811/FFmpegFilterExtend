//! C ABI of gpufx. See `include/gpufx.h` for the documented interface.
//!
//! Every function returning `int` returns 0 on success and a negative value on error;
//! functions returning pointers return NULL on error. `gpufx_last_error()` then describes
//! the failure for the calling thread.

#![allow(clippy::missing_safety_doc)]

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use gpufx_core::{
    Backend, ChromaLocation, ColorInfo, Effect, EffectChain, EffectGraph, Frame, FrameInfo, FrameMut, GpuContext, Image, ImageMut, Matrix,
    Package, PixelFormat, Program, Range, StreamInfo,
};

/// Bumped when the C ABI changes incompatibly. Must match `GPUFX_API_VERSION` in gpufx.h.
const API_VERSION: u32 = 9;

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
    CONTEXT_OPENS.fetch_add(1, Ordering::Relaxed);
    cache.insert(key, Arc::downgrade(&ctx));
    Ok(ctx)
}

/// The device effects are opened on until they are given theirs (see [`ready`]). It holds
/// no GPU memory, so it is kept for the life of the process.
fn noop_context() -> Result<Arc<GpuContext>, String> {
    static CACHE: Mutex<Option<Arc<GpuContext>>> = Mutex::new(None);
    let mut cache = CACHE.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(ctx) = cache.as_ref() {
        return Ok(ctx.clone());
    }
    let ctx = GpuContext::noop().map_err(|e| e.to_string())?;
    *cache = Some(ctx.clone());
    Ok(ctx)
}

/// Device string of an effect not on a device yet.
const NO_DEVICE: &str = "none yet: chosen by gpufx_effect_use_* or the first frame";

/// Packages read and compiled so far; lets tests check that the cache works.
static PROGRAM_LOADS: AtomicUsize = AtomicUsize::new(0);
/// Backend devices made so far; lets tests check that opening an effect makes none.
static CONTEXT_OPENS: AtomicUsize = AtomicUsize::new(0);

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

/// What an effect was opened from, to open it again on another device.
enum Spec {
    Chain(Vec<String>),
    Graph(String),
}

pub struct GpufxEffect {
    graph: EffectGraph,
    /// To open the effect again on its device (its backend's, or a shared one).
    spec: Spec,
    /// Backend of the device the effect runs on unless given a shared one; `Some` while
    /// the effect is on the noop device it was opened on.
    pending: Option<Backend>,
    name: CString,
    device: CString,
    inputs: Vec<CString>,
    input_formats: Vec<Vec<CString>>,
    outputs: Vec<CString>,
    output_formats: Vec<Vec<CString>>,
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

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GpufxColor {
    pub matrix: u32,
    pub range: u32,
    pub chroma_location: u32,
    pub flags: u32,
}

#[repr(C)]
pub struct GpufxFrame {
    pub format: *const c_char,
    pub width: u32,
    pub height: u32,
    pub data: [*const u8; 4],
    pub stride: [u32; 4],
    pub color: GpufxColor,
}

#[repr(C)]
pub struct GpufxFrameOut {
    pub format: *const c_char,
    pub width: u32,
    pub height: u32,
    pub data: [*mut u8; 4],
    pub stride: [u32; 4],
    pub color: GpufxColor,
}

const FRAME_PREMULTIPLIED: u32 = 1;

fn color_info(c: &GpufxColor) -> Result<ColorInfo, String> {
    let matrix = match c.matrix {
        0 => Matrix::Bt601,
        1 => Matrix::Bt709,
        2 => Matrix::Bt2020,
        m => return Err(format!("unknown colour matrix {m}")),
    };
    let range = match c.range {
        0 => Range::Limited,
        1 => Range::Full,
        r => return Err(format!("unknown range {r}")),
    };
    use ChromaLocation::*;
    let chroma_location = *[Left, Center, TopLeft, Top, BottomLeft, Bottom]
        .get(c.chroma_location as usize)
        .ok_or_else(|| format!("unknown chroma location {}", c.chroma_location))?;
    Ok(ColorInfo { matrix, range, chroma_location, premultiplied: c.flags & FRAME_PREMULTIPLIED != 0 })
}

unsafe fn pixel_format(name: *const c_char, what: &str) -> Result<PixelFormat, String> {
    let name = str_arg(name, what)?;
    PixelFormat::from_name(name).ok_or_else(|| format!("{what}: pixel format `{name}` is not converted on the GPU"))
}

/// Byte length of every plane of a `format` frame, checking the pointers.
fn plane_lens(what: &str, format: PixelFormat, w: u32, h: u32, nulls: [bool; 4], strides: [u32; 4]) -> Result<[usize; 4], String> {
    if w == 0 || h == 0 {
        return Err(format!("{what} is empty"));
    }
    // Far above what GPUs take (16384), and keeps the row sizes within u32.
    if w > 1 << 16 || h > 1 << 16 {
        return Err(format!("{what}: {w}x{h} is too large"));
    }
    let mut lens = [0; 4];
    for p in 0..format.plane_count() {
        let (row, rows) = format.plane_size(p, w, h);
        if nulls[p] {
            return Err(format!("{what}: plane {p} is NULL"));
        }
        if strides[p] < row {
            return Err(format!("{what}: stride {} of plane {p} is below {row} bytes", strides[p]));
        }
        lens[p] = (rows as usize - 1)
            .checked_mul(strides[p] as usize)
            .and_then(|n| n.checked_add(row as usize))
            .ok_or_else(|| format!("{what}: plane {p} is too large for the address space"))?;
    }
    Ok(lens)
}

/// Refuses an output plane that overlaps an input plane or another output plane: the
/// GPU result is copied into it while the inputs are still borrowed.
fn check_no_alias(inputs: &[Frame], outs: &[FrameMut]) -> Result<(), String> {
    let range = |s: &[u8]| (s.as_ptr() as usize, s.as_ptr() as usize + s.len());
    let outs: Vec<(usize, usize)> = outs.iter().flat_map(|o| o.planes.iter().filter(|p| !p.is_empty()).map(|p| range(p))).collect();
    let ins = inputs.iter().flat_map(|f| f.planes.iter().filter(|p| !p.is_empty()).map(|p| range(p)));
    let overlap = |a: (usize, usize), b: (usize, usize)| a.0 < b.1 && b.0 < a.1;
    for (i, &o) in outs.iter().enumerate() {
        if outs[..i].iter().any(|&p| overlap(o, p)) || ins.clone().any(|p| overlap(o, p)) {
            return Err(format!("out plane {i} overlaps another plane of the input or output frames"));
        }
    }
    Ok(())
}

unsafe fn frame_arg<'a>(f: &GpufxFrame, what: &str) -> Result<Frame<'a>, String> {
    let format = pixel_format(f.format, what)?;
    let lens = plane_lens(what, format, f.width, f.height, f.data.map(|d| d.is_null()), f.stride)?;
    let mut planes: [&[u8]; 4] = [&[]; 4];
    for p in 0..format.plane_count() {
        planes[p] = std::slice::from_raw_parts(f.data[p], lens[p]);
    }
    Ok(Frame { format, width: f.width, height: f.height, planes, strides: f.stride, color: color_info(&f.color)? })
}

unsafe fn frame_out_arg<'a>(f: &GpufxFrameOut, what: &str) -> Result<FrameMut<'a>, String> {
    let format = pixel_format(f.format, what)?;
    let lens = plane_lens(what, format, f.width, f.height, f.data.map(|d| d.is_null()), f.stride)?;
    let mut planes: [&mut [u8]; 4] = Default::default();
    for p in 0..format.plane_count() {
        planes[p] = std::slice::from_raw_parts_mut(f.data[p], lens[p]);
    }
    Ok(FrameMut { format, width: f.width, height: f.height, planes, strides: f.stride, color: color_info(&f.color)? })
}

/// Names of the formats converted on the GPU, as C strings.
fn format_names() -> &'static [CString] {
    static NAMES: OnceLock<Vec<CString>> = OnceLock::new();
    NAMES.get_or_init(|| PixelFormat::ALL.iter().map(|f| cstring(f.name())).collect())
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
pub extern "C" fn gpufx_format_count() -> u32 {
    format_names().len() as u32
}

#[no_mangle]
pub extern "C" fn gpufx_format_name(index: u32) -> *const c_char {
    format_names().get(index as usize).map_or(ptr::null(), |s| s.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_format_supported(format: *const c_char) -> c_int {
    if format.is_null() {
        return 0;
    }
    CStr::from_ptr(format).to_str().ok().and_then(PixelFormat::from_name).is_some() as c_int
}

/// Label of a package in parameter names: its file name without `.zip`.
fn label(path: &str) -> String {
    let p = std::path::Path::new(path);
    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| path.to_string());
    name.strip_suffix(".zip").or_else(|| name.strip_suffix(".ZIP")).unwrap_or(&name).to_string()
}

unsafe fn backend_arg(backend: *const c_char) -> Result<Backend, String> {
    if backend.is_null() {
        return Ok(Backend::Auto);
    }
    str_arg(backend, "backend")?.parse().map_err(|e: gpufx_core::Error| e.to_string())
}

fn wrap(graph: EffectGraph, spec: Spec, pending: Backend, name: String) -> *mut GpufxEffect {
    let strings = |list: &[String]| list.iter().map(|f| cstring(f)).collect::<Vec<_>>();
    let out = GpufxEffect {
        spec,
        pending: Some(pending),
        name: cstring(&name),
        device: cstring(NO_DEVICE),
        inputs: strings(graph.input_names()),
        input_formats: (0..graph.input_count()).map(|i| strings(graph.input_formats(i))).collect(),
        outputs: strings(graph.output_names()),
        output_formats: (0..graph.output_count()).map(|k| strings(graph.output_formats(k))).collect(),
        params: strings(graph.param_names()),
        graph,
    };
    Box::into_raw(Box::new(out))
}

/// Opens what `spec` describes on `ctx`, with the name of the effect.
fn open_spec(spec: &Spec, ctx: &Arc<GpuContext>) -> Result<(EffectGraph, String), String> {
    match spec {
        Spec::Chain(paths) => {
            let mut effects = Vec::with_capacity(paths.len());
            for path in paths {
                let effect = Effect::from_program(program(path, ctx.clone())?).map_err(|e| format!("{path}: {e}"))?;
                effects.push((label(path), effect));
            }
            let graph = EffectChain::new(effects).map_err(|e| e.to_string())?.into_graph();
            let names: Vec<&str> = graph.effects().iter().map(|fx| fx.package().manifest.name.as_str()).collect();
            let name = names.join(" | ");
            Ok((graph, name))
        }
        Spec::Graph(text) => {
            let graph = EffectGraph::parse(text, |path| {
                let effect = Effect::from_program(program(path, ctx.clone()).map_err(gpufx_core::Error::Package)?)
                    .map_err(|e| gpufx_core::Error::Package(format!("{path}: {e}")))?;
                Ok((label(path), effect))
            })
            .map_err(|e| e.to_string())?;
            let names: Vec<&str> = graph.effects().iter().map(|fx| fx.package().manifest.name.as_str()).collect();
            let name = format!("graph of {}", names.join(", "));
            Ok((graph, name))
        }
    }
}

/// Opens the effect on the noop device: the caller may give it a shared device before the
/// first frame (FFmpeg's, through gpufx_effect_use_*), so the backend's device is made only
/// when it is used (see [`ready`]).
unsafe fn open(spec: Spec, backend: *const c_char) -> Result<*mut GpufxEffect, String> {
    let backend = backend_arg(backend)?;
    let (graph, name) = open_spec(&spec, &noop_context()?)?;
    Ok(wrap(graph, spec, backend, name))
}

/// Opens the effect again on `ctx` with its parameter values, unless it runs there.
fn move_to(fx: &mut GpufxEffect, ctx: &Arc<GpuContext>, device: String) -> Result<(), String> {
    if !Arc::ptr_eq(fx.graph.context(), ctx) {
        let (mut graph, _) = open_spec(&fx.spec, ctx)?;
        graph.copy_params_from(&fx.graph).map_err(|e| e.to_string())?;
        fx.graph = graph;
        fx.device = cstring(&device);
    }
    fx.pending = None;
    Ok(())
}

/// Moves an effect still on the noop device to the device of its backend.
fn ready(fx: &mut GpufxEffect) -> Result<(), String> {
    if let Some(backend) = fx.pending {
        let ctx = context(backend).map_err(|e| e.to_string())?;
        move_to(fx, &ctx, ctx.description())?;
    }
    Ok(())
}

/// Frames from a host device need the effect on that device, given by `use`.
fn on_host_device(fx: &GpufxEffect, call: &str) -> Result<(), String> {
    match fx.pending {
        Some(_) => Err(format!("call {call} before processing its frames")),
        None => Ok(()),
    }
}

unsafe fn open_chain(paths: &[&str], backend: *const c_char) -> Result<*mut GpufxEffect, String> {
    open(Spec::Chain(paths.iter().map(|p| p.to_string()).collect()), backend)
}

unsafe fn open_graph(text: &str, backend: *const c_char) -> Result<*mut GpufxEffect, String> {
    open(Spec::Graph(text.to_string()), backend)
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
pub unsafe extern "C" fn gpufx_effect_open_graph(graph: *const c_char, backend: *const c_char) -> *mut GpufxEffect {
    guard(ptr::null_mut(), || open_graph(str_arg(graph, "graph")?, backend))
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
pub unsafe extern "C" fn gpufx_effect_use_default_device(fx: *mut GpufxEffect) -> c_int {
    guard(-1, || {
        ready(fx.as_mut().ok_or("effect is NULL")?)?;
        Ok(0)
    })
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
    gpufx_effect_output_pad_format_count(fx, 0)
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_output_format(fx: *const GpufxEffect, index: u32) -> *const c_char {
    gpufx_effect_output_pad_format(fx, 0, index)
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_output_count(fx: *const GpufxEffect) -> u32 {
    fx.as_ref().map_or(0, |fx| fx.outputs.len() as u32)
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_output_name(fx: *const GpufxEffect, output: u32) -> *const c_char {
    fx.as_ref().and_then(|fx| fx.outputs.get(output as usize)).map_or(ptr::null(), |s| s.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_output_source(fx: *const GpufxEffect, output: u32) -> c_int {
    guard(-1, || {
        let fx = fx.as_ref().ok_or("effect is NULL")?;
        if output as usize >= fx.graph.output_count() {
            return Err(format!("no output {output}"));
        }
        Ok(fx.graph.output_pad(output as usize) as c_int)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_output_pad_format_count(fx: *const GpufxEffect, output: u32) -> u32 {
    fx.as_ref().and_then(|fx| fx.output_formats.get(output as usize)).map_or(0, |f| f.len() as u32)
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_output_pad_format(fx: *const GpufxEffect, output: u32, index: u32) -> *const c_char {
    fx.as_ref()
        .and_then(|fx| fx.output_formats.get(output as usize))
        .and_then(|f| f.get(index as usize))
        .map_or(ptr::null(), |s| s.as_ptr())
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
        fx.graph.check_inputs(&infos).map_err(|e| e.to_string())?;
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
        let i = fx.graph.find_param(str_arg(name, "name")?).map_err(|e| e.to_string())?;
        Ok(i as c_int)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_set_param(fx: *mut GpufxEffect, name: *const c_char, value: *const c_char) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        let (name, value) = (str_arg(name, "name")?, str_arg(value, "value")?);
        fx.graph.set_param_str(name, value).map_err(|e| e.to_string())?;
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
        fx.graph.set_param(name, values).map_err(|e| e.to_string())?;
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
        ready(fx)?;
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
        single(fx)?;
        fx.graph.process(&images, vec![target], &info).map_err(|e| e.to_string())?;
        Ok(0)
    })
}

/// Inputs of a frame call, checked.
unsafe fn frames_arg<'a>(inputs: *const GpufxFrame, nb_inputs: u32) -> Result<Vec<Frame<'a>>, String> {
    if inputs.is_null() || nb_inputs == 0 {
        return Err("inputs must not be NULL".into());
    }
    let raw = std::slice::from_raw_parts(inputs, nb_inputs as usize);
    let mut frames = Vec::with_capacity(raw.len());
    for (i, f) in raw.iter().enumerate() {
        frames.push(frame_arg(f, &format!("input {i}"))?);
    }
    Ok(frames)
}

/// Outputs of a frame call, checked.
unsafe fn outs_arg<'a>(outs: *const GpufxFrameOut, nb_outputs: u32) -> Result<Vec<FrameMut<'a>>, String> {
    if outs.is_null() || nb_outputs == 0 {
        return Err("outs must not be NULL".into());
    }
    let raw = std::slice::from_raw_parts(outs, nb_outputs as usize);
    let mut frames = Vec::with_capacity(raw.len());
    for (k, f) in raw.iter().enumerate() {
        frames.push(frame_out_arg(f, &if raw.len() == 1 { "out".to_string() } else { format!("out {k}") })?);
    }
    Ok(frames)
}

/// The single-output functions refuse a graph with several outputs.
fn single(fx: &GpufxEffect) -> Result<(), String> {
    match fx.graph.output_count() {
        1 => Ok(()),
        n => Err(format!("the graph has {n} outputs; use gpufx_effect_process_graph()")),
    }
}

fn frame_info(info: &GpufxFrameInfo) -> FrameInfo {
    FrameInfo { time: info.time, frame: info.frame, pixel_aspect: info.pixel_aspect }
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_process_frames(
    fx: *mut GpufxEffect,
    inputs: *const GpufxFrame,
    nb_inputs: u32,
    out: *const GpufxFrameOut,
    info: *const GpufxFrameInfo,
) -> c_int {
    if let Some(fx) = fx.as_ref() {
        if guard(true, || single(fx).map(|()| false)) {
            return -1;
        }
    }
    gpufx_effect_process_graph(fx, inputs, nb_inputs, out, 1, info)
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_process_graph(
    fx: *mut GpufxEffect,
    inputs: *const GpufxFrame,
    nb_inputs: u32,
    outs: *const GpufxFrameOut,
    nb_outputs: u32,
    info: *const GpufxFrameInfo,
) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        ready(fx)?;
        let info = frame_info(info.as_ref().ok_or("info is NULL")?);
        let frames = frames_arg(inputs, nb_inputs)?;
        let mut outs = outs_arg(outs, nb_outputs)?;
        check_no_alias(&frames, &outs)?;
        fx.graph.process_frames(&frames, &mut outs, &info).map_err(|e| e.to_string())?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_convert_frame(fx: *mut GpufxEffect, input: *const GpufxFrame, out: *const GpufxFrameOut) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        single(fx)?;
        ready(fx)?;
        let input = frame_arg(input.as_ref().ok_or("input is NULL")?, "input")?;
        let mut outs = outs_arg(out, 1)?;
        check_no_alias(std::slice::from_ref(&input), &outs)?;
        fx.graph.convert(std::slice::from_ref(&input), &mut outs).map_err(|e| e.to_string())?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_convert_graph(
    fx: *mut GpufxEffect,
    inputs: *const GpufxFrame,
    nb_inputs: u32,
    outs: *const GpufxFrameOut,
    nb_outputs: u32,
) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        ready(fx)?;
        let frames = frames_arg(inputs, nb_inputs)?;
        let mut outs = outs_arg(outs, nb_outputs)?;
        check_no_alias(&frames, &outs)?;
        fx.graph.convert(&frames, &mut outs).map_err(|e| e.to_string())?;
        Ok(0)
    })
}

// ---- Vulkan frames (since version 6) ----

#[repr(C)]
pub struct GpufxVulkanDevice {
    pub get_instance_proc_addr: *const c_void,
    pub instance: *mut c_void,
    pub physical_device: *mut c_void,
    pub device: *mut c_void,
    pub api_version: u32,
    pub queue_family: u32,
    pub queue_index: u32,
    pub queue_flags: u32,
    pub nb_instance_extensions: u32,
    pub instance_extensions: *const *const c_char,
    pub nb_device_extensions: u32,
    pub device_extensions: *const *const c_char,
    pub device_features: *const c_void,
}

#[repr(C)]
pub struct GpufxVulkanFrame {
    pub format: *const c_char,
    pub width: u32,
    pub height: u32,
    pub nb_images: u32,
    pub image: [u64; 4],
    pub vk_format: [i32; 4],
    pub layout: [i32; 4],
    pub semaphore: [u64; 4],
    pub sem_value: [u64; 4],
    pub queue_family: [u32; 4],
    pub color: GpufxColor,
}

#[cfg(any(windows, all(unix, not(target_vendor = "apple"))))]
mod vk {
    use super::*;
    use gpufx_core::vulkan::{VulkanDevice, VulkanFrame, VulkanPlane};

    unsafe fn strings(list: *const *const c_char, n: u32, what: &str) -> Result<Vec<String>, String> {
        if n == 0 {
            return Ok(Vec::new());
        }
        if list.is_null() {
            return Err(format!("{what} is NULL"));
        }
        std::slice::from_raw_parts(list, n as usize).iter().map(|&p| str_arg(p, what).map(str::to_string)).collect()
    }

    /// Shared Vulkan devices, by VkDevice, while an effect uses them.
    fn vulkan_context(desc: &VulkanDevice) -> Result<Arc<GpuContext>, String> {
        type Cache = Mutex<Vec<(usize, Weak<GpuContext>)>>;
        static CACHE: Cache = Mutex::new(Vec::new());
        let mut cache = CACHE.lock().unwrap_or_else(|p| p.into_inner());
        cache.retain(|(_, w)| w.strong_count() > 0);
        if let Some(ctx) = cache.iter().find(|(d, _)| *d == desc.device as usize).and_then(|(_, w)| w.upgrade()) {
            return Ok(ctx);
        }
        let ctx = unsafe { GpuContext::from_vulkan(desc) }.map_err(|e| e.to_string())?;
        cache.push((desc.device as usize, Arc::downgrade(&ctx)));
        Ok(ctx)
    }

    pub unsafe fn use_vulkan(fx: &mut GpufxEffect, dev: &GpufxVulkanDevice) -> Result<(), String> {
        let desc = VulkanDevice {
            get_instance_proc_addr: dev.get_instance_proc_addr,
            instance: dev.instance,
            physical_device: dev.physical_device,
            device: dev.device,
            api_version: dev.api_version,
            instance_extensions: strings(dev.instance_extensions, dev.nb_instance_extensions, "instance_extensions")?,
            device_extensions: strings(dev.device_extensions, dev.nb_device_extensions, "device_extensions")?,
            enabled_features: dev.device_features,
            queue_family: dev.queue_family,
            queue_index: dev.queue_index,
            queue_flags: dev.queue_flags,
        };
        let ctx = vulkan_context(&desc)?;
        move_to(fx, &ctx, shared_device(&ctx, "Vulkan"))
    }

    /// Device string of an effect on a device shared with the caller.
    pub fn shared_device(ctx: &GpuContext, api: &str) -> String {
        format!("{} ({api} device shared with the caller)", ctx.description())
    }

    unsafe fn frame(f: &GpufxVulkanFrame, what: &str) -> Result<VulkanFrame, String> {
        let format = pixel_format(f.format, what)?;
        if f.width == 0 || f.height == 0 || f.width > 1 << 16 || f.height > 1 << 16 {
            return Err(format!("{what}: bad size {}x{}", f.width, f.height));
        }
        if f.nb_images as usize > 4 {
            return Err(format!("{what}: {} images", f.nb_images));
        }
        let planes = (0..f.nb_images as usize)
            .map(|i| VulkanPlane {
                image: f.image[i],
                format: f.vk_format[i],
                layout: f.layout[i],
                semaphore: f.semaphore[i],
                value: f.sem_value[i],
                queue_family: f.queue_family[i],
            })
            .collect();
        Ok(VulkanFrame { format, width: f.width, height: f.height, planes, color: color_info(&f.color)? })
    }

    unsafe fn frames(list: *mut GpufxVulkanFrame, n: u32, what: &str) -> Result<Vec<VulkanFrame>, String> {
        if list.is_null() || n == 0 {
            return Err(format!("{what} must not be NULL"));
        }
        std::slice::from_raw_parts(list, n as usize).iter().enumerate().map(|(i, f)| frame(f, &format!("{what} {i}"))).collect()
    }

    fn write_back(frames: &[VulkanFrame], raw: &mut [GpufxVulkanFrame]) {
        for (f, r) in frames.iter().zip(raw) {
            for (i, p) in f.planes.iter().enumerate() {
                r.layout[i] = p.layout;
                r.sem_value[i] = p.value;
            }
        }
    }

    pub unsafe fn process(
        fx: &mut GpufxEffect,
        inputs: *mut GpufxVulkanFrame,
        nb_inputs: u32,
        outs: *mut GpufxVulkanFrame,
        nb_outputs: u32,
        info: Option<FrameInfo>,
    ) -> Result<(), String> {
        let mut ins = frames(inputs, nb_inputs, "input")?;
        let mut os = frames(outs, nb_outputs, "out")?;
        fx.graph.process_vulkan(&mut ins, &mut os, info.as_ref()).map_err(|e| e.to_string())?;
        write_back(&ins, std::slice::from_raw_parts_mut(inputs, nb_inputs as usize));
        write_back(&os, std::slice::from_raw_parts_mut(outs, nb_outputs as usize));
        Ok(())
    }
}

#[cfg(not(any(windows, all(unix, not(target_vendor = "apple")))))]
mod vk {
    use super::*;
    const MSG: &str = "this libgpufx is built without Vulkan frame support";
    pub unsafe fn use_vulkan(_: &mut GpufxEffect, _: &GpufxVulkanDevice) -> Result<(), String> {
        Err(MSG.into())
    }
    pub unsafe fn process(
        _: &mut GpufxEffect,
        _: *mut GpufxVulkanFrame,
        _: u32,
        _: *mut GpufxVulkanFrame,
        _: u32,
        _: Option<FrameInfo>,
    ) -> Result<(), String> {
        Err(MSG.into())
    }
}

#[no_mangle]
pub extern "C" fn gpufx_vulkan_supported() -> c_int {
    cfg!(any(windows, all(unix, not(target_vendor = "apple")))) as c_int
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_use_vulkan(fx: *mut GpufxEffect, dev: *const GpufxVulkanDevice) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        vk::use_vulkan(fx, dev.as_ref().ok_or("device is NULL")?)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_process_vulkan(
    fx: *mut GpufxEffect,
    inputs: *mut GpufxVulkanFrame,
    nb_inputs: u32,
    outs: *mut GpufxVulkanFrame,
    nb_outputs: u32,
    info: *const GpufxFrameInfo,
) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        on_host_device(fx, "gpufx_effect_use_vulkan")?;
        vk::process(fx, inputs, nb_inputs, outs, nb_outputs, info.as_ref().map(frame_info))?;
        Ok(0)
    })
}

// ---- D3D12 and D3D11 frames (since version 7, Windows) ----

#[repr(C)]
pub struct GpufxD3D12Device {
    pub device: *mut c_void,
}

#[repr(C)]
pub struct GpufxD3D12Frame {
    pub format: *const c_char,
    pub width: u32,
    pub height: u32,
    pub resource: *mut c_void,
    pub subresource: u32,
    pub fence: *mut c_void,
    pub fence_value: u64,
    pub color: GpufxColor,
}

#[repr(C)]
pub struct GpufxD3D11Device {
    pub device: *mut c_void,
    pub device_context: *mut c_void,
}

#[repr(C)]
pub struct GpufxD3D11Frame {
    pub format: *const c_char,
    pub width: u32,
    pub height: u32,
    pub texture: *mut c_void,
    pub array_slice: u32,
    pub color: GpufxColor,
}

#[cfg(windows)]
mod dx {
    use super::*;
    use gpufx_core::d3d12::{D3d11Frame, D3d12Frame};

    /// Shared D3D12/D3D11 contexts, by caller device, while an effect uses them.
    fn shared(key: usize, make: impl FnOnce() -> Result<Arc<GpuContext>, gpufx_core::Error>) -> Result<Arc<GpuContext>, String> {
        type Cache = Mutex<Vec<(usize, Weak<GpuContext>)>>;
        static CACHE: Cache = Mutex::new(Vec::new());
        let mut cache = CACHE.lock().unwrap_or_else(|p| p.into_inner());
        cache.retain(|(_, w)| w.strong_count() > 0);
        if let Some(ctx) = cache.iter().find(|(d, _)| *d == key).and_then(|(_, w)| w.upgrade()) {
            return Ok(ctx);
        }
        let ctx = make().map_err(|e| e.to_string())?;
        cache.push((key, Arc::downgrade(&ctx)));
        Ok(ctx)
    }

    pub unsafe fn use_d3d12(fx: &mut GpufxEffect, dev: &GpufxD3D12Device) -> Result<(), String> {
        let ctx = shared(dev.device as usize, || GpuContext::from_d3d12(dev.device))?;
        move_to(fx, &ctx, vk::shared_device(&ctx, "D3D12"))
    }

    pub unsafe fn use_d3d11(fx: &mut GpufxEffect, dev: &GpufxD3D11Device) -> Result<(), String> {
        let ctx = shared(dev.device as usize, || GpuContext::from_d3d11(dev.device, dev.device_context))?;
        move_to(fx, &ctx, vk::shared_device(&ctx, "D3D11"))
    }

    unsafe fn list<'a, T>(p: *mut T, n: u32, what: &str) -> Result<&'a mut [T], String> {
        if p.is_null() || n == 0 {
            return Err(format!("{what} must not be NULL"));
        }
        Ok(std::slice::from_raw_parts_mut(p, n as usize))
    }

    fn size(w: u32, h: u32, what: &str) -> Result<(), String> {
        if w == 0 || h == 0 || w > 1 << 16 || h > 1 << 16 {
            return Err(format!("{what}: bad size {w}x{h}"));
        }
        Ok(())
    }

    unsafe fn d3d12_frames(raw: &[GpufxD3D12Frame], what: &str) -> Result<Vec<D3d12Frame>, String> {
        raw.iter()
            .enumerate()
            .map(|(i, f)| {
                let what = format!("{what} {i}");
                size(f.width, f.height, &what)?;
                Ok(D3d12Frame {
                    format: pixel_format(f.format, &what)?,
                    width: f.width,
                    height: f.height,
                    resource: f.resource,
                    subresource: f.subresource,
                    fence: f.fence,
                    fence_value: f.fence_value,
                    color: color_info(&f.color)?,
                })
            })
            .collect()
    }

    pub unsafe fn process_d3d12(
        fx: &mut GpufxEffect,
        inputs: *mut GpufxD3D12Frame,
        nb_inputs: u32,
        outs: *mut GpufxD3D12Frame,
        nb_outputs: u32,
        info: Option<FrameInfo>,
    ) -> Result<(), String> {
        let (ri, ro) = (list(inputs, nb_inputs, "inputs")?, list(outs, nb_outputs, "outs")?);
        let mut ins = d3d12_frames(ri, "input")?;
        let mut os = d3d12_frames(ro, "out")?;
        fx.graph.process_d3d12(&mut ins, &mut os, info.as_ref()).map_err(|e| e.to_string())?;
        for (f, r) in ins.iter().zip(ri.iter_mut()).chain(os.iter().zip(ro.iter_mut())) {
            r.fence_value = f.fence_value;
        }
        Ok(())
    }

    unsafe fn d3d11_frames(raw: &[GpufxD3D11Frame], what: &str) -> Result<Vec<D3d11Frame>, String> {
        raw.iter()
            .enumerate()
            .map(|(i, f)| {
                let what = format!("{what} {i}");
                size(f.width, f.height, &what)?;
                Ok(D3d11Frame {
                    format: pixel_format(f.format, &what)?,
                    width: f.width,
                    height: f.height,
                    texture: f.texture,
                    array_slice: f.array_slice,
                    color: color_info(&f.color)?,
                })
            })
            .collect()
    }

    pub unsafe fn process_d3d11(
        fx: &mut GpufxEffect,
        inputs: *const GpufxD3D11Frame,
        nb_inputs: u32,
        outs: *const GpufxD3D11Frame,
        nb_outputs: u32,
        info: Option<FrameInfo>,
    ) -> Result<(), String> {
        let ins = d3d11_frames(list(inputs as *mut GpufxD3D11Frame, nb_inputs, "inputs")?, "input")?;
        let os = d3d11_frames(list(outs as *mut GpufxD3D11Frame, nb_outputs, "outs")?, "out")?;
        fx.graph.process_d3d11(&ins, &os, info.as_ref()).map_err(|e| e.to_string())
    }
}

#[cfg(not(windows))]
mod dx {
    use super::*;
    const MSG: &str = "D3D12 and D3D11 frames are only supported on Windows";
    pub unsafe fn use_d3d12(_: &mut GpufxEffect, _: &GpufxD3D12Device) -> Result<(), String> {
        Err(MSG.into())
    }
    pub unsafe fn use_d3d11(_: &mut GpufxEffect, _: &GpufxD3D11Device) -> Result<(), String> {
        Err(MSG.into())
    }
    pub unsafe fn process_d3d12(
        _: &mut GpufxEffect,
        _: *mut GpufxD3D12Frame,
        _: u32,
        _: *mut GpufxD3D12Frame,
        _: u32,
        _: Option<FrameInfo>,
    ) -> Result<(), String> {
        Err(MSG.into())
    }
    pub unsafe fn process_d3d11(
        _: &mut GpufxEffect,
        _: *const GpufxD3D11Frame,
        _: u32,
        _: *const GpufxD3D11Frame,
        _: u32,
        _: Option<FrameInfo>,
    ) -> Result<(), String> {
        Err(MSG.into())
    }
}

#[no_mangle]
pub extern "C" fn gpufx_d3d12_supported() -> c_int {
    cfg!(windows) as c_int
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_use_d3d12(fx: *mut GpufxEffect, dev: *const GpufxD3D12Device) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        dx::use_d3d12(fx, dev.as_ref().ok_or("device is NULL")?)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_process_d3d12(
    fx: *mut GpufxEffect,
    inputs: *mut GpufxD3D12Frame,
    nb_inputs: u32,
    outs: *mut GpufxD3D12Frame,
    nb_outputs: u32,
    info: *const GpufxFrameInfo,
) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        on_host_device(fx, "gpufx_effect_use_d3d12")?;
        dx::process_d3d12(fx, inputs, nb_inputs, outs, nb_outputs, info.as_ref().map(frame_info))?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_use_d3d11(fx: *mut GpufxEffect, dev: *const GpufxD3D11Device) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        dx::use_d3d11(fx, dev.as_ref().ok_or("device is NULL")?)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_process_d3d11(
    fx: *mut GpufxEffect,
    inputs: *const GpufxD3D11Frame,
    nb_inputs: u32,
    outs: *const GpufxD3D11Frame,
    nb_outputs: u32,
    info: *const GpufxFrameInfo,
) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        on_host_device(fx, "gpufx_effect_use_d3d11")?;
        dx::process_d3d11(fx, inputs, nb_inputs, outs, nb_outputs, info.as_ref().map(frame_info))?;
        Ok(0)
    })
}

// ---- VideoToolbox frames (since version 9, macOS) ----

#[repr(C)]
pub struct GpufxVtFrame {
    pub format: *const c_char,
    pub width: u32,
    pub height: u32,
    pub pixel_buffer: *mut c_void,
    pub color: GpufxColor,
}

#[cfg(target_vendor = "apple")]
mod vt {
    use super::*;
    use gpufx_core::videotoolbox::VtFrame;

    /// The context for VideoToolbox frames, while an effect uses it.
    fn context() -> Result<Arc<GpuContext>, String> {
        static CACHE: Mutex<Weak<GpuContext>> = Mutex::new(Weak::new());
        let mut cache = CACHE.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(ctx) = cache.upgrade() {
            return Ok(ctx);
        }
        let ctx = GpuContext::from_videotoolbox().map_err(|e| e.to_string())?;
        *cache = Arc::downgrade(&ctx);
        Ok(ctx)
    }

    pub fn use_videotoolbox(fx: &mut GpufxEffect) -> Result<(), String> {
        let ctx = context()?;
        let device = format!("{} (VideoToolbox frames)", ctx.description());
        move_to(fx, &ctx, device)
    }

    unsafe fn frames(p: *const GpufxVtFrame, n: u32, what: &str) -> Result<Vec<VtFrame>, String> {
        if p.is_null() || n == 0 {
            return Err(format!("{what} must not be NULL"));
        }
        std::slice::from_raw_parts(p, n as usize)
            .iter()
            .enumerate()
            .map(|(i, f)| {
                let what = format!("{what} {i}");
                if f.width == 0 || f.height == 0 || f.width > 1 << 16 || f.height > 1 << 16 {
                    return Err(format!("{what}: bad size {}x{}", f.width, f.height));
                }
                Ok(VtFrame {
                    format: pixel_format(f.format, &what)?,
                    width: f.width,
                    height: f.height,
                    pixel_buffer: f.pixel_buffer,
                    color: color_info(&f.color)?,
                })
            })
            .collect()
    }

    pub unsafe fn process(
        fx: &mut GpufxEffect,
        inputs: *const GpufxVtFrame,
        nb_inputs: u32,
        outs: *const GpufxVtFrame,
        nb_outputs: u32,
        info: Option<FrameInfo>,
    ) -> Result<(), String> {
        let ins = frames(inputs, nb_inputs, "inputs")?;
        let os = frames(outs, nb_outputs, "outs")?;
        fx.graph.process_videotoolbox(&ins, &os, info.as_ref()).map_err(|e| e.to_string())
    }
}

#[cfg(not(target_vendor = "apple"))]
mod vt {
    use super::*;
    const MSG: &str = "VideoToolbox frames are only supported on macOS";
    pub fn use_videotoolbox(_: &mut GpufxEffect) -> Result<(), String> {
        Err(MSG.into())
    }
    pub unsafe fn process(
        _: &mut GpufxEffect,
        _: *const GpufxVtFrame,
        _: u32,
        _: *const GpufxVtFrame,
        _: u32,
        _: Option<FrameInfo>,
    ) -> Result<(), String> {
        Err(MSG.into())
    }
}

#[no_mangle]
pub extern "C" fn gpufx_videotoolbox_supported() -> c_int {
    cfg!(target_vendor = "apple") as c_int
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_use_videotoolbox(fx: *mut GpufxEffect) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        vt::use_videotoolbox(fx)?;
        Ok(0)
    })
}

#[no_mangle]
pub unsafe extern "C" fn gpufx_effect_process_videotoolbox(
    fx: *mut GpufxEffect,
    inputs: *const GpufxVtFrame,
    nb_inputs: u32,
    outs: *const GpufxVtFrame,
    nb_outputs: u32,
    info: *const GpufxFrameInfo,
) -> c_int {
    guard(-1, || {
        let fx = fx.as_mut().ok_or("effect is NULL")?;
        on_host_device(fx, "gpufx_effect_use_videotoolbox")?;
        vt::process(fx, inputs, nb_inputs, outs, nb_outputs, info.as_ref().map(frame_info))?;
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
    fn an_effect_gets_its_device_at_the_first_frame() {
        let _serial = serial();
        if GpuContext::new(Backend::Auto).is_err() {
            eprintln!("skipping: no GPU adapter");
            return;
        }
        let examples = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/effects");
        let opens = || CONTEXT_OPENS.load(Ordering::Relaxed);
        let start = opens();
        // Kept alive so the next effect would find it in the cache.
        let fx = open(&examples.join("invert"));
        assert!(!fx.is_null(), "{:?}", unsafe { CStr::from_ptr(gpufx_last_error()) });
        unsafe {
            // Opening, describing and setting parameters make no device: a filter given
            // FFmpeg's device never makes its own.
            let (name, value) = (CString::new("amount").unwrap(), CString::new("0.25").unwrap());
            assert_eq!(gpufx_effect_set_param(fx, name.as_ptr(), value.as_ptr()), 0);
            let format = CString::new("rgba").unwrap();
            let stream = GpufxStreamInfo { format: format.as_ptr(), width: 4, height: 2 };
            assert_eq!(gpufx_effect_check_inputs(fx, &stream, 1), 0);
            assert_eq!(opens(), start, "no device before the first frame");
            assert_eq!(CStr::from_ptr(gpufx_effect_device(fx)).to_str().unwrap(), NO_DEVICE);

            let data = [10u8, 20, 30, 255].repeat(8);
            let mut out = [0u8; 32];
            let image = GpufxImage { data: data.as_ptr(), width: 4, height: 2, stride: 16 };
            let target = GpufxOutput { data: out.as_mut_ptr(), width: 4, height: 2, stride: 16 };
            let info = GpufxFrameInfo { time: 0.0, frame: 0, pixel_aspect: 1.0 };
            assert_eq!(gpufx_effect_process(fx, &image, 1, &target, &info), 0, "{:?}", CStr::from_ptr(gpufx_last_error()));
            assert_ne!(CStr::from_ptr(gpufx_effect_device(fx)).to_str().unwrap(), NO_DEVICE);
            // The parameter set before the move is kept: a quarter of the way to the inverse, not the full 245.
            assert!((60..80).contains(&out[0]), "{out:?}");
            assert_eq!(gpufx_effect_use_default_device(fx), 0);
            gpufx_effect_free(fx);
        }
    }

    #[test]
    fn host_frames_before_use_fail_clearly() {
        let _serial = serial();
        let examples = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/effects");
        let fx = open(&examples.join("invert"));
        assert!(!fx.is_null(), "{:?}", unsafe { CStr::from_ptr(gpufx_last_error()) });
        unsafe {
            // Still on the noop device: running there would write nothing and report success.
            let rc = gpufx_effect_process_vulkan(fx, ptr::null_mut(), 0, ptr::null_mut(), 0, ptr::null());
            assert_eq!(rc, -1);
            let err = CStr::from_ptr(gpufx_last_error()).to_str().unwrap().to_string();
            assert!(err.contains("gpufx_effect_use_vulkan"), "{err}");
            gpufx_effect_free(fx);
        }
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
        let (pa, pb) = unsafe { ((*a).graph.effects()[0].params().bytes(), (*b).graph.effects()[0].params().bytes()) };
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

    #[test]
    fn planar_frames_are_converted_on_the_gpu() {
        let _serial = serial();
        if GpuContext::new(Backend::Auto).is_err() {
            eprintln!("skipping: no GPU adapter");
            return;
        }
        let examples = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/effects");
        let fx = open(&examples.join("invert"));
        assert!(!fx.is_null());
        assert!(unsafe { gpufx_format_supported(c"p010le".as_ptr()) } == 1);
        assert!(unsafe { gpufx_format_supported(c"yuvj420p".as_ptr()) } == 1);
        assert!(unsafe { gpufx_format_supported(c"gray".as_ptr()) } == 0);
        let names: Vec<String> =
            (0..gpufx_format_count()).map(|i| unsafe { CStr::from_ptr(gpufx_format_name(i)) }.to_str().unwrap().into()).collect();
        assert!(names.contains(&"nv12".to_string()) && names.contains(&"yuv420p10le".to_string()), "{names:?}");

        // BT.709 limited white, 4x2 NV12 with padded rows.
        let y = [235u8; 8 * 2];
        let uv = [128u8; 8];
        let color = GpufxColor { matrix: 1, range: 0, chroma_location: 0, flags: 0 };
        let input = GpufxFrame {
            format: c"nv12".as_ptr(),
            width: 4,
            height: 2,
            data: [y.as_ptr(), uv.as_ptr(), ptr::null(), ptr::null()],
            stride: [8, 8, 0, 0],
            color,
        };
        let mut out = [0u8; 4 * 4 * 2];
        let target = GpufxFrameOut {
            format: c"rgba".as_ptr(),
            width: 4,
            height: 2,
            data: [out.as_mut_ptr(), ptr::null_mut(), ptr::null_mut(), ptr::null_mut()],
            stride: [16, 0, 0, 0],
            color,
        };
        let info = GpufxFrameInfo { time: 0.0, frame: 0, pixel_aspect: 1.0 };
        assert_eq!(unsafe { gpufx_effect_process_frames(fx, &input, 1, &target, &info) }, 0, "{:?}", unsafe {
            CStr::from_ptr(gpufx_last_error())
        });
        assert_eq!(out[..4], [0, 0, 0, 255]);
        assert_eq!(unsafe { gpufx_effect_convert_frame(fx, &input, &target) }, 0);
        assert_eq!(out[..4], [255, 255, 255, 255]);
        // A missing plane is an error, not a crash.
        let broken = GpufxFrame { data: [y.as_ptr(), ptr::null(), ptr::null(), ptr::null()], ..input };
        assert!(unsafe { gpufx_effect_process_frames(fx, &broken, 1, &target, &info) } < 0);
        assert!(unsafe { CStr::from_ptr(gpufx_last_error()) }.to_str().unwrap().contains("plane 1 is NULL"));
        // Writing over the input is refused.
        let mut same = y;
        let inplace = GpufxFrame { data: [same.as_ptr(), uv.as_ptr(), ptr::null(), ptr::null()], ..input };
        let over =
            GpufxFrameOut { data: [same.as_mut_ptr(), ptr::null_mut(), ptr::null_mut(), ptr::null_mut()], width: 2, height: 2, ..target };
        let small = GpufxFrame { width: 2, height: 2, ..inplace };
        assert!(unsafe { gpufx_effect_convert_frame(fx, &small, &over) } < 0);
        assert!(unsafe { CStr::from_ptr(gpufx_last_error()) }.to_str().unwrap().contains("overlaps"));
        unsafe { gpufx_effect_free(fx) };
    }

    #[test]
    fn a_graph_has_several_outputs() {
        let _serial = serial();
        if GpuContext::new(Backend::Auto).is_err() {
            eprintln!("skipping: no GPU adapter");
            return;
        }
        let examples = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/effects");
        let invert = examples.join("invert");
        let text = CString::new(format!("[0]split[a][keep]; [a]{}[inv]", invert.display())).unwrap();
        let fx = unsafe { gpufx_effect_open_graph(text.as_ptr(), ptr::null()) };
        assert!(!fx.is_null(), "{:?}", unsafe { CStr::from_ptr(gpufx_last_error()) });
        let name = |s: *const c_char| unsafe { CStr::from_ptr(s) }.to_str().unwrap().to_string();
        unsafe {
            assert_eq!((gpufx_effect_input_count(fx), gpufx_effect_output_count(fx)), (1, 2));
            assert_eq!(name(gpufx_effect_input_name(fx, 0)), "in0");
            assert_eq!(name(gpufx_effect_output_name(fx, 0)), "keep");
            assert_eq!(name(gpufx_effect_output_name(fx, 1)), "inv");
            assert_eq!(gpufx_effect_output_source(fx, 1), 0);
            assert!(gpufx_effect_output_source(fx, 2) < 0);
            assert!(gpufx_effect_output_pad_format_count(fx, 1) > 0);
            assert_eq!(name(gpufx_effect_param_name(fx, 0)), "amount");
            assert!(gpufx_effect_find_param(fx, c"inv.amount".as_ptr()) == 0);
        }
        let src = [200u8; 4 * 4 * 4];
        let (mut keep, mut inv) = ([0u8; 64], [0u8; 64]);
        let input = GpufxFrame {
            format: c"rgba".as_ptr(),
            width: 4,
            height: 4,
            data: [src.as_ptr(), ptr::null(), ptr::null(), ptr::null()],
            stride: [16, 0, 0, 0],
            color: GpufxColor { matrix: 0, range: 1, chroma_location: 0, flags: 0 },
        };
        let out = |data: &mut [u8; 64]| GpufxFrameOut {
            format: c"rgba".as_ptr(),
            width: 4,
            height: 4,
            data: [data.as_mut_ptr(), ptr::null_mut(), ptr::null_mut(), ptr::null_mut()],
            stride: [16, 0, 0, 0],
            color: input.color,
        };
        let outs = [out(&mut keep), out(&mut inv)];
        let info = GpufxFrameInfo { time: 0.0, frame: 0, pixel_aspect: 1.0 };
        assert_eq!(unsafe { gpufx_effect_process_graph(fx, &input, 1, outs.as_ptr(), 2, &info) }, 0, "{:?}", unsafe {
            CStr::from_ptr(gpufx_last_error())
        });
        assert_eq!((keep[0], inv[0], inv[3]), (200, 55, 200));
        // The single output functions refuse it, and so do overlapping outputs.
        assert!(unsafe { gpufx_effect_process_frames(fx, &input, 1, &outs[0], &info) } < 0);
        assert!(name(gpufx_last_error()).contains("use gpufx_effect_process_graph()"), "{}", name(gpufx_last_error()));
        assert!(unsafe { gpufx_effect_convert_frame(fx, &input, &outs[0]) } < 0);
        let same = [out(&mut keep), out(&mut keep)];
        assert!(unsafe { gpufx_effect_process_graph(fx, &input, 1, same.as_ptr(), 2, &info) } < 0);
        assert_eq!(unsafe { gpufx_effect_convert_graph(fx, &input, 1, outs.as_ptr(), 2) }, 0);
        assert_eq!((keep[0], inv[0]), (200, 200));
        unsafe { gpufx_effect_free(fx) };
        // Mistakes come back as errors.
        let bad = CString::new("[0]split[a]; [a]nothing.zip[b]").unwrap();
        assert!(unsafe { gpufx_effect_open_graph(bad.as_ptr(), ptr::null()) }.is_null());
        assert!(name(gpufx_last_error()).contains("nothing.zip"), "{}", name(gpufx_last_error()));
    }
}
