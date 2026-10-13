//! Textures and buffers shared by every graph and effect of one [`crate::GpuContext`].
//!
//! A graph borrows its per-frame resources (pass outputs, converted inputs, upload planes,
//! output words) before recording a frame and gives them back right after the submission
//! that uses them. Every user submits to the one queue of the context, so the GPU runs
//! a later borrower's work after the earlier one's: nothing is kept from frame to frame
//! in these resources. The pool hands a borrower the resources it had last time when
//! they are idle, so its bind groups stay valid and nothing is rebuilt per frame.

use std::collections::HashMap;
use std::sync::Mutex;

/// What a pooled resource is made for; only a resource of the same key is handed out.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum PoolKey {
    Texture { width: u32, height: u32, format: wgpu::TextureFormat, usage: wgpu::TextureUsages, mips: bool },
    Buffer { size: u64, usage: wgpu::BufferUsages },
}

impl PoolKey {
    fn bytes(&self) -> u64 {
        match *self {
            PoolKey::Texture { width, height, format, mips, .. } => {
                let texel = format.block_copy_size(None).unwrap_or(4) as u64;
                let chain = if mips { crate::mips::chain_bytes(width, height, texel) } else { 0 };
                width as u64 * height as u64 * texel + chain
            }
            PoolKey::Buffer { size, .. } => size,
        }
    }

    fn create(&self, device: &wgpu::Device) -> Resource {
        match *self {
            PoolKey::Texture { width, height, format, usage, mips } => {
                Resource::Texture(crate::convert::texture_2d_mips(device, "gpufx pooled texture", width, height, format, usage, mips))
            }
            PoolKey::Buffer { size, usage } => Resource::Buffer(device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("gpufx pooled buffer"),
                size,
                usage,
                mapped_at_creation: false,
            })),
        }
    }
}

#[derive(Clone)]
pub(crate) enum Resource {
    Texture(wgpu::Texture),
    Buffer(wgpu::Buffer),
}

/// A borrowed resource. `id` is unique per pooled resource: the same id means the same
/// texture or buffer, so bind groups made for it are still valid.
#[derive(Clone)]
pub(crate) struct Lease {
    pub id: u64,
    pub resource: Resource,
}

impl Lease {
    pub fn texture(&self) -> &wgpu::Texture {
        match &self.resource {
            Resource::Texture(t) => t,
            Resource::Buffer(_) => panic!("a pooled buffer used as a texture"),
        }
    }

    pub fn buffer(&self) -> &wgpu::Buffer {
        match &self.resource {
            Resource::Buffer(b) => b,
            Resource::Texture(_) => panic!("a pooled texture used as a buffer"),
        }
    }
}

/// What the pool of a context holds; see [`crate::GpuContext::pool_stats`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PoolStats {
    /// Resources (textures and buffers) waiting for a borrower, and their bytes.
    pub idle: usize,
    pub idle_bytes: u64,
    /// Resources borrowed by a frame being recorded, and their bytes.
    pub borrowed: usize,
    pub borrowed_bytes: u64,
    /// Most bytes the pool held at once, idle and borrowed.
    pub peak_bytes: u64,
    /// Resources made since the context was created.
    pub created: usize,
}

struct Entry {
    key: PoolKey,
    id: u64,
    resource: Resource,
    bytes: u64,
    borrowed: bool,
    /// Tick of the last give back.
    idle_since: u64,
}

#[derive(Default)]
struct Inner {
    entries: Vec<Entry>,
    next_id: u64,
    next_user: u64,
    /// One tick per give back.
    tick: u64,
    /// Last tick of every borrower, to count the borrowers of a frame.
    users: HashMap<u64, u64>,
    held_bytes: u64,
    peak_bytes: u64,
    created: usize,
}

/// A resource idle for this many frames is freed (a frame being one give back per active
/// borrower), so a new size does not keep the textures of the old one.
const IDLE_FRAMES: u64 = 4;
/// A borrower that gave nothing back for this many ticks no longer counts as active.
const USER_TICKS: u64 = 256;

#[derive(Default)]
pub(crate) struct Pool {
    inner: Mutex<Inner>,
}

impl Pool {
    /// An id for a new borrower (a graph's frame resources).
    pub fn new_user(&self) -> u64 {
        let mut inner = self.lock();
        inner.next_user += 1;
        inner.next_user
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Borrows one resource per key, preferring the given id (the one borrowed last time)
    /// when it is idle, then any idle resource of the key, else a new one.
    pub fn take(&self, device: &wgpu::Device, wants: &[(PoolKey, Option<u64>)]) -> Vec<Lease> {
        let mut inner = self.lock();
        let mut got: Vec<Option<Lease>> = vec![None; wants.len()];
        // Preferred ids first, so a later key cannot take the one an earlier key had.
        for (slot, &(key, prefer)) in got.iter_mut().zip(wants) {
            let Some(id) = prefer else { continue };
            if let Some(e) = inner.entries.iter_mut().find(|e| e.id == id && !e.borrowed && e.key == key) {
                e.borrowed = true;
                *slot = Some(Lease { id: e.id, resource: e.resource.clone() });
            }
        }
        for (slot, &(key, _)) in got.iter_mut().zip(wants) {
            if slot.is_some() {
                continue;
            }
            if let Some(e) = inner.entries.iter_mut().find(|e| !e.borrowed && e.key == key) {
                e.borrowed = true;
                *slot = Some(Lease { id: e.id, resource: e.resource.clone() });
                continue;
            }
            inner.next_id += 1;
            let id = inner.next_id;
            let resource = key.create(device);
            let bytes = key.bytes();
            inner.entries.push(Entry { key, id, resource: resource.clone(), bytes, borrowed: true, idle_since: 0 });
            inner.held_bytes += bytes;
            inner.peak_bytes = inner.peak_bytes.max(inner.held_bytes);
            inner.created += 1;
            *slot = Some(Lease { id, resource });
        }
        got.into_iter().map(|l| l.expect("filled above")).collect()
    }

    /// Gives back what `user` borrowed, once the submission using it was made, and frees
    /// what stayed idle for [`IDLE_FRAMES`] frames.
    pub fn give_back(&self, user: u64, ids: &[u64]) {
        let mut inner = self.lock();
        inner.tick += 1;
        let tick = inner.tick;
        for e in inner.entries.iter_mut().filter(|e| ids.contains(&e.id)) {
            e.borrowed = false;
            e.idle_since = tick;
        }
        inner.users.insert(user, tick);
        inner.users.retain(|_, &mut t| tick - t <= USER_TICKS);
        let limit = IDLE_FRAMES * inner.users.len().max(1) as u64;
        let mut freed = 0;
        inner.entries.retain(|e| {
            let keep = e.borrowed || tick - e.idle_since <= limit;
            if !keep {
                freed += e.bytes;
            }
            keep
        });
        inner.held_bytes -= freed;
    }

    /// Gives back resources borrowed past the submission (a readback buffer, once unmapped)
    /// without counting a frame: [`Pool::give_back`] of the same frame did.
    pub fn put_back(&self, ids: &[u64]) {
        let mut inner = self.lock();
        let tick = inner.tick;
        for e in inner.entries.iter_mut().filter(|e| ids.contains(&e.id)) {
            e.borrowed = false;
            e.idle_since = tick;
        }
    }

    /// Drops borrowed resources that must not be handed out again.
    pub fn forget(&self, ids: &[u64]) {
        let mut inner = self.lock();
        let mut freed = 0;
        inner.entries.retain(|e| {
            let keep = !ids.contains(&e.id);
            if !keep {
                freed += e.bytes;
            }
            keep
        });
        inner.held_bytes -= freed;
    }

    pub fn stats(&self) -> PoolStats {
        let inner = self.lock();
        let mut s = PoolStats { peak_bytes: inner.peak_bytes, created: inner.created, ..Default::default() };
        for e in &inner.entries {
            if e.borrowed {
                s.borrowed += 1;
                s.borrowed_bytes += e.bytes;
            } else {
                s.idle += 1;
                s.idle_bytes += e.bytes;
            }
        }
        s
    }
}
