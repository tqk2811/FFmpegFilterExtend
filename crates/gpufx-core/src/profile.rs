//! Opt-in timings of GPU frames: set `GPUFX_PROFILE=1` and every graph prints, when it
//! is dropped, how long the GPU spent per frame converting its inputs, running its
//! effects and writing its outputs (timestamp queries, when the device has them), and
//! how long the CPU spent recording and submitting. Off, nothing is created or measured.

use std::sync::OnceLock;
use std::time::Duration;

/// Whether `GPUFX_PROFILE` is set to something other than `0`.
pub(crate) fn enabled() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var("GPUFX_PROFILE").is_ok_and(|v| !v.is_empty() && v != "0"))
}

/// The optional features a device asks for: [`crate::runtime::GPU_FEATURES`], plus
/// timestamp queries when profiling.
pub(crate) fn features() -> wgpu::Features {
    let base = crate::runtime::GPU_FEATURES;
    if enabled() {
        base | wgpu::Features::TIMESTAMP_QUERY
    } else {
        base
    }
}

/// GPU spans of a frame, each one compute pass.
pub(crate) const COPY_IN: u32 = 0;
pub(crate) const EFFECTS: u32 = 1;
pub(crate) const COPY_OUT: u32 = 2;
const SPANS: usize = 3;
const GPU_NAMES: [&str; SPANS] = ["copy-in", "effects", "copy-out"];

/// CPU spans of a frame.
#[derive(Clone, Copy)]
pub(crate) enum Cpu {
    /// Planning and borrowing the pooled textures (`prepare`).
    Prepare = 0,
    /// Bind groups of the frame's input and output images.
    Bind,
    /// Recording the passes.
    Record,
    /// Wrapping the frame's images (Vulkan).
    Import,
    /// `queue.submit` and the semaphores around it.
    Submit,
    /// Waiting for the frame's validation scope.
    Scope,
    /// The whole call.
    Total,
}
const CPU_NAMES: [&str; 7] = ["prepare", "bind", "record", "import", "submit", "error scope", "total"];

/// Results are read back this many frames later, so reading rarely waits for the GPU.
const RING: usize = 4;
const BYTES: u64 = (SPANS * 2 * 8) as u64;

/// The query set, the buffer it resolves into, and the read buffers with whether each
/// holds a frame not read yet.
type Queries = (wgpu::QuerySet, wgpu::Buffer, Vec<(wgpu::Buffer, bool)>);

pub(crate) struct Profiler {
    label: String,
    device: wgpu::Device,
    /// Timestamps, when the device has the feature.
    queries: Option<Queries>,
    next: usize,
    period: f64,
    gpu_ns: [f64; SPANS],
    gpu_frames: u64,
    cpu: [Duration; CPU_NAMES.len()],
    cpu_frames: [u64; CPU_NAMES.len()],
}

impl Profiler {
    pub fn new(device: &wgpu::Device, queue: &wgpu::Queue, label: String) -> Self {
        let queries = device.features().contains(wgpu::Features::TIMESTAMP_QUERY).then(|| {
            let set = device.create_query_set(&wgpu::QuerySetDescriptor {
                label: Some("gpufx profile"),
                ty: wgpu::QueryType::Timestamp,
                count: (SPANS * 2) as u32,
            });
            let resolve = device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("gpufx profile resolve"),
                size: BYTES,
                usage: wgpu::BufferUsages::QUERY_RESOLVE | wgpu::BufferUsages::COPY_SRC,
                mapped_at_creation: false,
            });
            let reads = (0..RING)
                .map(|_| {
                    let b = device.create_buffer(&wgpu::BufferDescriptor {
                        label: Some("gpufx profile read"),
                        size: BYTES,
                        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
                        mapped_at_creation: false,
                    });
                    (b, false)
                })
                .collect();
            (set, resolve, reads)
        });
        Profiler {
            label,
            device: device.clone(),
            queries,
            next: 0,
            period: queue.get_timestamp_period() as f64,
            gpu_ns: [0.0; SPANS],
            gpu_frames: 0,
            cpu: [Duration::ZERO; CPU_NAMES.len()],
            cpu_frames: [0; CPU_NAMES.len()],
        }
    }

    /// Whether the GPU spans are measured: the frame's passes are then split per span.
    pub fn timed(&self) -> bool {
        self.queries.is_some()
    }

    pub fn writes(&self, span: u32) -> Option<wgpu::ComputePassTimestampWrites<'_>> {
        self.queries.as_ref().map(|(set, _, _)| wgpu::ComputePassTimestampWrites {
            query_set: set,
            beginning_of_pass_write_index: Some(span * 2),
            end_of_pass_write_index: Some(span * 2 + 1),
        })
    }

    /// Resolves the frame's timestamps into the next read buffer, collecting what that
    /// buffer held from `RING` frames ago first.
    pub fn finish(&mut self, enc: &mut wgpu::CommandEncoder) {
        let n = self.next;
        self.next = (n + 1) % RING;
        self.collect(n);
        let Some((set, resolve, reads)) = &mut self.queries else { return };
        enc.resolve_query_set(set, 0..(SPANS * 2) as u32, resolve, 0);
        enc.copy_buffer_to_buffer(resolve, 0, &reads[n].0, 0, BYTES);
        reads[n].1 = true;
    }

    fn collect(&mut self, n: usize) {
        let Some((_, _, reads)) = &mut self.queries else { return };
        let (buf, pending) = &mut reads[n];
        if !std::mem::take(pending) {
            return;
        }
        let slice = buf.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |r| {
            let _ = tx.send(r.is_ok());
        });
        let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
        if rx.recv().unwrap_or(false) {
            let t: Vec<u64> = match slice.get_mapped_range() {
                Ok(view) => view.chunks_exact(8).map(|c| u64::from_le_bytes(c.try_into().unwrap())).collect(),
                Err(_) => Vec::new(),
            };
            // A frame whose passes did not all run (an error, a dropped encoder) is skipped.
            if t.len() == SPANS * 2 && t.iter().all(|&v| v != 0) && t.chunks_exact(2).all(|p| p[1] >= p[0]) {
                for (s, p) in t.chunks_exact(2).enumerate() {
                    self.gpu_ns[s] += (p[1] - p[0]) as f64 * self.period;
                }
                self.gpu_frames += 1;
            }
            buf.unmap();
        }
    }

    pub fn cpu(&mut self, span: Cpu, d: Duration) {
        self.cpu[span as usize] += d;
        self.cpu_frames[span as usize] += 1;
    }
}

impl Drop for Profiler {
    fn drop(&mut self) {
        for n in 0..RING {
            self.collect(n);
        }
        let mut line = format!("gpufx profile [{}]", self.label);
        if self.gpu_frames > 0 {
            let f = self.gpu_frames as f64;
            line += &format!(" GPU ms/frame over {} frames:", self.gpu_frames);
            for (name, ns) in GPU_NAMES.iter().zip(self.gpu_ns) {
                line += &format!(" {name} {:.3}", ns / f / 1e6);
            }
            line += ";";
        }
        line += " CPU ms/frame:";
        for ((name, d), n) in CPU_NAMES.iter().zip(self.cpu).zip(self.cpu_frames) {
            if n > 0 {
                line += &format!(" {name} {:.3}", d.as_secs_f64() * 1e3 / n as f64);
            }
        }
        eprintln!("{line}");
    }
}
