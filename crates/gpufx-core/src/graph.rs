//! Effects wired as a graph (a DAG) and run in one GPU submission: chains
//! (`a.zip|b.zip`) and graphs (`[0]split[a][b]; [a]blur.zip[x]; ...`) share this engine.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use crate::convert::{read_outputs, readback_buffer, work_format, GpuOutputSlot, InputKey, InputSlot, OutputSlot};
use crate::frame::{Frame, FrameMut, GpuFrame, PixelFormat};
use crate::manifest::StreamInfo;
use crate::mips::MipChain;
use crate::params::ParamBlock;
use crate::pool::PoolKey;
use crate::runtime::{Effect, FrameInfo, Image, ImageMut};
use crate::Error;

/// Where an effect input or a graph output takes its frame from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// An input pad of the graph (`[0]`, `[1]`...).
    Input(usize),
    /// The output of an effect, by its index in [`EffectGraph::effects`].
    Node(usize),
}

/// The wiring of a graph: every effect input and graph output names its source.
pub(crate) struct Topology {
    pub nb_inputs: usize,
    /// The sources of the inputs of each effect, in manifest order.
    pub node_inputs: Vec<Vec<Source>>,
    /// Effects in an order where each comes after the effects it reads.
    pub order: Vec<usize>,
    pub outputs: Vec<Source>,
}

impl Topology {
    /// One effect reading every input pad.
    pub fn single(nb_inputs: usize) -> Self {
        Topology {
            nb_inputs,
            node_inputs: vec![(0..nb_inputs).map(Source::Input).collect()],
            order: vec![0],
            outputs: vec![Source::Node(0)],
        }
    }

    /// The input pad whose size `src` has: an effect writes the size of its first input.
    pub fn pad_of(&self, src: Source) -> usize {
        match src {
            Source::Input(i) => i,
            Source::Node(j) => self.pad_of(self.node_inputs[j][0]),
        }
    }

    /// Size of every effect output for the given pad sizes.
    fn node_sizes(&self, pads: &[(u32, u32)]) -> Vec<(u32, u32)> {
        (0..self.node_inputs.len()).map(|k| pads[self.pad_of(Source::Node(k))]).collect()
    }
}

/// GPU memory a graph holds for its current frame sizes and formats.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MemoryStats {
    /// Pooled textures for pass outputs, chain links and graph edges. Textures whose
    /// lifetimes do not overlap share one, so this is the peak number alive at once.
    pub pass_textures: usize,
    pub pass_texture_bytes: u64,
    /// Upload textures of the inputs: the planes and, unless straight RGBA, the
    /// converted frame. One set per input pad, whatever reads it.
    pub input_textures: usize,
    pub input_texture_bytes: u64,
    /// The one mappable buffer every output is read back through.
    pub readback_bytes: u64,
}

/// Frame upload, conversion and readback resources, shared by the effects of a graph.
#[derive(Default)]
pub(crate) struct FrameIo {
    /// How many times textures or bind groups were made; see [`EffectGraph::allocations`].
    allocations: usize,
    /// The frames of the graph carry more than 8 bits: see [`work_format`].
    deep: bool,
    inputs: Vec<InputSlot>,
    outputs: Vec<OutputSlot>,
    /// Outputs written into GPU frames.
    gpu_outputs: Vec<GpuOutputSlot>,
    readback: Option<wgpu::Buffer>,
    memory: MemoryStats,
    /// Mip chains of the input pads and effect outputs an effect input wants mipmapped.
    input_mips: Vec<Option<MipChain>>,
    node_mips: Vec<Option<MipChain>>,
    /// What `prepare` planned for the current inputs; the textures come from the pool.
    layout: Option<Layout>,
    /// Ids of the pooled resources the bind groups were made for: the input slots and
    /// pass textures, then the output words. Another id back from the pool rebinds.
    bound_ids: Vec<u64>,
    out_ids: Vec<u64>,
    /// Borrowed for the frame being recorded, given back once it is submitted.
    borrowed: Vec<u64>,
    /// The pool's id of this borrower, and the context of the pool.
    user: u64,
    ctx: Option<Arc<crate::GpuContext>>,
}

/// The planned textures of a graph for one set of inputs.
struct Layout {
    keys: Vec<InputKey>,
    plan: Plan,
    sizes: Vec<(u32, u32)>,
    pad_mips: Vec<bool>,
    node_mips: Vec<bool>,
}

impl FrameIo {
    /// Gives back what the last frame borrowed: its submission was made (or nothing was).
    pub(crate) fn release(&mut self) {
        if let Some(ctx) = &self.ctx {
            if !self.borrowed.is_empty() {
                ctx.pool.give_back(self.user, &std::mem::take(&mut self.borrowed));
            }
        }
    }
}

impl Drop for FrameIo {
    fn drop(&mut self) {
        self.release();
    }
}

/// Which input pads and effect outputs some effect reads through a `mipmaps` input.
fn mip_sources(effects: &[Effect], topo: &Topology) -> (Vec<bool>, Vec<bool>) {
    let mut pads = vec![false; topo.nb_inputs];
    let mut nodes = vec![false; effects.len()];
    for (k, sources) in topo.node_inputs.iter().enumerate() {
        for (def, src) in effects[k].package().manifest.inputs.iter().zip(sources) {
            if def.mipmaps {
                match *src {
                    Source::Input(i) => pads[i] = true,
                    Source::Node(j) => nodes[j] = true,
                }
            }
        }
    }
    (pads, nodes)
}

/// Which pooled texture each pass output gets, and the size of each pooled texture.
struct Plan {
    assign: Vec<HashMap<String, usize>>,
    /// Size of each pooled texture, and whether it has a mip chain.
    slots: Vec<(u32, u32, bool)>,
}

impl Plan {
    fn bytes(&self, deep: bool) -> u64 {
        let texel = if deep { 8 } else { 4 };
        self.slots
            .iter()
            .map(|&(w, h, mips)| w as u64 * h as u64 * texel + if mips { crate::mips::chain_bytes(w, h, texel) } else { 0 })
            .sum()
    }
}

/// Assigns the pass outputs of every effect to pooled textures: a texture goes back to
/// the pool (per size) after the last pass that reads it, counted over the whole graph
/// in execution order. Graph outputs stay alive until they are read back. The outputs of
/// the effects in `mips` get pooled textures with a mip chain, kept apart from the others.
fn plan(effects: &[Effect], topo: &Topology, sizes: &[(u32, u32)], mips: &[bool], deep: bool) -> Result<Plan, Error> {
    let finals: Vec<&str> =
        effects.iter().map(|fx| fx.program.package.manifest.passes.last().expect("validated").output.as_str()).collect();
    let mut last: HashMap<(usize, &str), usize> = HashMap::new();
    fn bump<'a>(last: &mut HashMap<(usize, &'a str), usize>, key: (usize, &'a str), g: usize) {
        let end = last.entry(key).or_insert(g);
        *end = (*end).max(g);
    }
    let mut g = 0;
    for &k in &topo.order {
        let m = &effects[k].program.package.manifest;
        let passes = effects[k].passes(deep)?;
        for pass in passes {
            for name in &pass.inputs {
                if let Some(p) = passes.iter().find(|p| p.output == *name) {
                    bump(&mut last, (k, p.output.as_str()), g);
                } else if let Some(i) = m.inputs.iter().position(|d| d.name == *name) {
                    // The output of another effect is this effect's input.
                    if let Source::Node(j) = topo.node_inputs[k][i] {
                        bump(&mut last, (j, finals[j]), g);
                    }
                }
            }
            bump(&mut last, (k, pass.output.as_str()), g);
            g += 1;
        }
    }
    for src in &topo.outputs {
        if let Source::Node(j) = *src {
            // Read by the output conversion, after every effect.
            last.insert((j, finals[j]), usize::MAX);
        }
    }

    let mut free: HashMap<(u32, u32, bool), Vec<usize>> = HashMap::new();
    let mut live: Vec<(usize, usize)> = Vec::new();
    let mut slots: Vec<(u32, u32, bool)> = Vec::new();
    let mut assign = vec![HashMap::new(); effects.len()];
    let mut g = 0;
    for &k in &topo.order {
        for pass in effects[k].passes(deep)? {
            live.retain(|&(end, slot)| {
                if end < g {
                    free.entry(slots[slot]).or_default().push(slot);
                }
                end >= g
            });
            if !assign[k].contains_key(&pass.output) {
                let key = (sizes[k].0, sizes[k].1, mips[k] && pass.output == finals[k]);
                let slot = free.get_mut(&key).and_then(|f| f.pop()).unwrap_or_else(|| {
                    slots.push(key);
                    slots.len() - 1
                });
                live.push((last[&(k, pass.output.as_str())], slot));
                assign[k].insert(pass.output.clone(), slot);
            }
            g += 1;
        }
    }
    Ok(Plan { assign, slots })
}

/// Checks every effect against its manifest rules: an input pad gives its stream, an
/// edge the size of the effect writing it and the format negotiated for it (`links`).
fn check_nodes<'a>(
    effects: &[Effect],
    topo: &Topology,
    links: Option<&'a [Vec<Option<String>>]>,
    streams: &[StreamInfo<'a>],
) -> Result<(), Error> {
    let pads: Vec<(u32, u32)> = streams.iter().map(|s| (s.width, s.height)).collect();
    let sizes = topo.node_sizes(&pads);
    for &k in &topo.order {
        let infos: Vec<StreamInfo> = topo.node_inputs[k]
            .iter()
            .enumerate()
            .map(|(i, src)| match *src {
                Source::Input(p) => streams[p],
                Source::Node(j) => StreamInfo { format: links.and_then(|l| l[k][i].as_deref()), width: sizes[j].0, height: sizes[j].1 },
            })
            .collect();
        effects[k].package().manifest.check_inputs(&infos)?;
    }
    Ok(())
}

fn source_texture(effects: &[Effect], inputs: &[InputSlot], src: Source) -> wgpu::Texture {
    match src {
        Source::Input(i) => inputs[i].texture.clone(),
        Source::Node(j) => effects[j].output().clone(),
    }
}

/// What the engine needs to know of a frame, in CPU or GPU memory.
#[derive(Clone, Copy)]
struct Desc {
    format: PixelFormat,
    width: u32,
    height: u32,
    premultiplied: bool,
}

/// Checks the frame counts and output sizes of a call, and (re)makes the input slots,
/// pooled textures and effect bind groups when the inputs changed.
fn prepare(
    effects: &mut [Effect],
    topo: &Topology,
    io: &mut FrameIo,
    inputs: &[Desc],
    outs: &[Desc],
    bypass: bool,
    gpu: bool,
) -> Result<(), Error> {
    if bypass {
        if inputs.is_empty() || inputs.len() > topo.nb_inputs {
            return Err(Error::Frame(format!("bypass takes 1 to {} inputs, got {}", topo.nb_inputs, inputs.len())));
        }
    } else if inputs.len() != topo.nb_inputs {
        return Err(Error::Frame(format!("effect expects {} inputs, got {}", topo.nb_inputs, inputs.len())));
    }
    if outs.len() != topo.outputs.len() {
        return Err(Error::Frame(format!("effect writes {} outputs, got {}", topo.outputs.len(), outs.len())));
    }
    for (k, out) in outs.iter().enumerate() {
        let what = if outs.len() == 1 { "output".to_string() } else { format!("output {k}") };
        let pad = topo.pad_of(topo.outputs[k]);
        let Some(f) = inputs.get(pad) else {
            return Err(Error::Frame(format!("{what} has the size of input {pad}, which is not given")));
        };
        let (w, h) = (f.width, f.height);
        if (out.width, out.height) != (w, h) {
            let of = if pad == 0 { "the first input".to_string() } else { format!("input {pad}") };
            return Err(Error::Frame(format!("{what} is {}x{}, the effect writes {w}x{h} (the size of {of})", out.width, out.height)));
        }
    }

    let ctx = effects[0].program.ctx.clone();
    let keys: Vec<InputKey> = inputs
        .iter()
        .map(|f| InputKey {
            format: f.format,
            width: f.width,
            height: f.height,
            direct: !gpu && f.format == PixelFormat::Rgba && !f.premultiplied,
            gpu,
        })
        .collect();
    let planned: &[InputKey] = io.layout.as_ref().map_or(&[], |l| &l.keys);
    // A bypass call may bring only the first inputs: keep the slots of the others, and
    // their depth, so toggling the filter on and off does not rebuild anything.
    let others = if bypass { planned.get(inputs.len()..).unwrap_or_default() } else { &[][..] };
    let deep = keys.iter().chain(others).any(|k| work_format(k.format) != wgpu::TextureFormat::Rgba8Unorm)
        || outs.iter().any(|o| work_format(o.format) != wgpu::TextureFormat::Rgba8Unorm);
    let stale = io.deep != deep
        || if bypass { planned.len() < keys.len() } else { planned.len() != keys.len() }
        || planned.iter().zip(&keys).any(|(p, k)| p != k);
    if stale {
        let mut keys = keys.clone();
        // Missing inputs keep their keys, or take input 0's when there are none yet.
        for i in keys.len()..topo.nb_inputs {
            keys.push(planned.get(i).copied().unwrap_or(keys[0]));
        }
        // Size rules of the manifests; pixel formats are the caller's to check.
        let streams: Vec<StreamInfo> = keys.iter().map(|k| StreamInfo { format: None, width: k.width, height: k.height }).collect();
        check_nodes(effects, topo, None, &streams)?;
        let pads: Vec<(u32, u32)> = keys.iter().map(|k| (k.width, k.height)).collect();
        let sizes = topo.node_sizes(&pads);
        let (pad_mips, node_mips) = mip_sources(effects, topo);
        let plan = plan(effects, topo, &sizes, &node_mips, deep)?;
        // Drop the bindings of the old textures; they go back to the pool's trimming.
        io.input_mips.clear();
        io.node_mips.clear();
        io.inputs.clear();
        io.outputs.clear();
        io.gpu_outputs.clear();
        io.readback = None;
        io.bound_ids.clear();
        io.out_ids.clear();
        for fx in effects.iter_mut() {
            fx.bound = None;
        }
        io.deep = deep;
        io.memory = MemoryStats { pass_textures: plan.slots.len(), pass_texture_bytes: plan.bytes(deep), ..Default::default() };
        io.layout = Some(Layout { keys, plan, sizes, pad_mips, node_mips });
    }
    acquire(effects, topo, io, &ctx)
}

/// Borrows the input slot and pass textures of a frame from the context pool, and
/// rebinds the slots and effects when the pool gave other textures than last time.
fn acquire(effects: &mut [Effect], topo: &Topology, io: &mut FrameIo, ctx: &Arc<crate::GpuContext>) -> Result<(), Error> {
    let (device, conv) = (&ctx.device, &ctx.conv);
    // Given back after the submission of the frame before, unless the caller did.
    io.release();
    if io.user == 0 {
        io.user = ctx.pool.new_user();
        io.ctx = Some(ctx.clone());
    }
    // Taken out while the slots are rebuilt, put back below.
    let layout = io.layout.take().expect("planned before");
    let deep = io.deep;
    let format = if deep { wgpu::TextureFormat::Rgba16Float } else { wgpu::TextureFormat::Rgba8Unorm };
    let usage = wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING;
    let mut keys = Vec::new();
    let mut counts = Vec::new();
    for (i, &k) in layout.keys.iter().enumerate() {
        let slot = InputSlot::pool_keys(k, deep, layout.pad_mips[i]);
        counts.push(slot.len());
        keys.extend(slot);
    }
    keys.extend(layout.plan.slots.iter().map(|&(width, height, mips)| PoolKey::Texture { width, height, format, usage, mips }));
    let wants: Vec<(PoolKey, Option<u64>)> = keys.iter().enumerate().map(|(n, &k)| (k, io.bound_ids.get(n).copied())).collect();
    let leases = ctx.pool.take(device, &wants);
    let ids: Vec<u64> = leases.iter().map(|l| l.id).collect();
    io.borrowed = ids.clone();
    if ids == io.bound_ids {
        io.layout = Some(layout);
        return Ok(());
    }
    io.bound_ids.clear();
    let mut textures = leases.iter().map(|l| l.texture().clone());
    io.input_mips.clear();
    io.node_mips.clear();
    io.inputs = layout
        .keys
        .iter()
        .zip(&counts)
        .map(|(&k, &n)| InputSlot::new(device, conv, k, deep, textures.by_ref().take(n).collect()))
        .collect();
    let pool: Vec<wgpu::Texture> = textures.collect();
    for &k in &topo.order {
        let sources: Vec<wgpu::Texture> = topo.node_inputs[k].iter().map(|&s| source_texture(effects, &io.inputs, s)).collect();
        let outputs = layout.plan.assign[k].iter().map(|(name, &slot)| (name.clone(), pool[slot].clone())).collect();
        if let Err(e) = effects[k].bind(&sources.iter().collect::<Vec<_>>(), outputs, layout.sizes[k], deep) {
            io.release();
            io.layout = Some(layout);
            return Err(e);
        }
    }
    io.input_mips = io.inputs.iter().zip(&layout.pad_mips).map(|(slot, &m)| m.then(|| ctx.mips.chain(device, &slot.texture))).collect();
    io.node_mips = (0..effects.len()).map(|k| layout.node_mips[k].then(|| ctx.mips.chain(device, effects[k].output()))).collect();
    for slot in &mut io.outputs {
        slot.unbind();
    }
    io.memory.input_textures = io.inputs.iter().map(|s| s.texture_count()).sum();
    io.memory.input_texture_bytes = io.inputs.iter().map(|s| s.texture_bytes()).sum();
    io.bound_ids = ids;
    io.layout = Some(layout);
    io.allocations += 1;
    Ok(())
}

fn desc_of(f: &Frame) -> Desc {
    Desc { format: f.format, width: f.width, height: f.height, premultiplied: f.color.premultiplied }
}

/// Runs the effects of `topo`: every input is uploaded once, every pass goes into one
/// command buffer in topological order and every output is read back once, through one
/// shared buffer. Without `info` the effects are bypassed: each output is its source
/// input pad (the pad whose size it has) converted to the output format; `inputs` may
/// then hold only the first pads.
pub(crate) fn run(
    effects: &mut [Effect],
    topo: &Topology,
    io: &mut FrameIo,
    inputs: &[Frame],
    outs: &mut [FrameMut],
    info: Option<&FrameInfo>,
) -> Result<(), Error> {
    let bypass = info.is_none();
    if !bypass {
        for fx in effects.iter_mut() {
            // Already reported when set through a graph; the last good shaders keep running.
            if let Err(e) = fx.sync_exprs() {
                eprintln!("gpufx: {e}; keeping the previous expressions");
            }
        }
    }
    for (i, f) in inputs.iter().enumerate() {
        f.check(&format!("input {i}"))?;
    }
    for (k, out) in outs.iter().enumerate() {
        out.check(&if outs.len() == 1 { "output".to_string() } else { format!("output {k}") })?;
    }
    let ins: Vec<Desc> = inputs.iter().map(desc_of).collect();
    let out_descs: Vec<Desc> =
        outs.iter().map(|o| Desc { format: o.format, width: o.width, height: o.height, premultiplied: o.color.premultiplied }).collect();
    prepare(effects, topo, io, &ins, &out_descs, bypass, false)?;

    let ctx = effects[0].program.ctx.clone();
    let (device, queue, conv) = (&ctx.device, &ctx.queue, &ctx.conv);
    if io.outputs.len() != outs.len() || io.outputs.iter().zip(outs.iter()).any(|(slot, o)| slot.key != (o.format, o.width, o.height)) {
        io.outputs.clear();
        io.readback = None;
        io.out_ids.clear();
        let mut offset = 0;
        for o in outs.iter() {
            let slot = match OutputSlot::new(device, o.format, o.width, o.height, offset) {
                Ok(slot) => slot,
                Err(e) => {
                    io.release();
                    return Err(e);
                }
            };
            offset = slot.end();
            io.outputs.push(slot);
        }
        io.readback = Some(readback_buffer(device, offset));
        io.memory.readback_bytes = offset;
    }
    // The output words are pooled too: the readback buffer, which the CPU maps, is not.
    let keys: Vec<PoolKey> = io.outputs.iter().flat_map(|slot| slot.pool_keys()).collect();
    let wants: Vec<(PoolKey, Option<u64>)> = keys.iter().enumerate().map(|(n, &k)| (k, io.out_ids.get(n).copied())).collect();
    let leases = ctx.pool.take(device, &wants);
    let ids: Vec<u64> = leases.iter().map(|l| l.id).collect();
    io.borrowed.extend(&ids);
    if ids != io.out_ids {
        let mut buffers = leases.iter().map(|l| l.buffer().clone());
        for slot in &mut io.outputs {
            let n = slot.pool_keys().len();
            slot.set_words(buffers.by_ref().take(n).collect());
        }
        io.out_ids = ids;
    }
    let mut bound = false;
    for k in 0..outs.len() {
        if !io.outputs[k].is_bound(bypass) {
            let src = if bypass { Source::Input(topo.pad_of(topo.outputs[k])) } else { topo.outputs[k] };
            let tex = source_texture(effects, &io.inputs, src);
            io.outputs[k].bind(device, conv, &tex, bypass);
            bound = true;
        }
    }
    io.allocations += bound as usize;

    for (slot, f) in io.inputs.iter().zip(inputs) {
        slot.upload(queue, &f.planes, &f.strides, &f.color);
    }
    let mut enc = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("gpufx") });
    {
        let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("gpufx"), timestamp_writes: None });
        encode_effects(effects, topo, io, inputs.len(), info, &mut cpass);
        for (slot, out) in io.outputs.iter().zip(outs.iter()) {
            slot.encode(queue, conv, &mut cpass, &out.color, bypass);
        }
    }
    let readback = io.readback.clone().expect("made above");
    for slot in &io.outputs {
        slot.copy(&mut enc, &readback);
    }
    queue.submit([enc.finish()]);
    // Later submissions may reuse the pooled resources: the GPU runs them after this one.
    io.release();
    read_outputs(device, &readback, &io.outputs, outs)
}

/// Encodes the conversion of the first `given` inputs and, unless bypassed (no `info`),
/// every effect in order, each mip chain right after the texture it is made from.
fn encode_effects(
    effects: &[Effect],
    topo: &Topology,
    io: &FrameIo,
    given: usize,
    info: Option<&FrameInfo>,
    cpass: &mut wgpu::ComputePass,
) {
    let ctx = &effects[0].program.ctx;
    for (i, slot) in io.inputs[..given].iter().enumerate() {
        slot.encode(&ctx.conv, cpass);
        if let (Some(Some(chain)), Some(_)) = (io.input_mips.get(i), info) {
            chain.encode(&ctx.device, &ctx.mips, cpass);
        }
    }
    if let Some(info) = info {
        for &k in &topo.order {
            effects[k].encode(cpass, info);
            if let Some(Some(chain)) = io.node_mips.get(k) {
                chain.encode(&ctx.device, &ctx.mips, cpass);
            }
        }
    }
}

/// [`run`] for frames already on the GPU: the conversion passes read the input plane
/// textures and write the output plane textures directly, and everything is recorded
/// into `enc` without being submitted or waited for (the caller submits it, with
/// whatever synchronisation the frames need, before the next call).
pub(crate) fn run_gpu(
    effects: &mut [Effect],
    topo: &Topology,
    io: &mut FrameIo,
    inputs: &[GpuFrame],
    outs: &[GpuFrame],
    info: Option<&FrameInfo>,
    enc: &mut wgpu::CommandEncoder,
) -> Result<(), Error> {
    let bypass = info.is_none();
    if !bypass {
        for fx in effects.iter_mut() {
            // Already reported when set through a graph; the last good shaders keep running.
            if let Err(e) = fx.sync_exprs() {
                eprintln!("gpufx: {e}; keeping the previous expressions");
            }
        }
    }
    for (i, f) in inputs.iter().enumerate() {
        f.check(&format!("input {i}"), false)?;
    }
    for (k, out) in outs.iter().enumerate() {
        out.check(&if outs.len() == 1 { "output".to_string() } else { format!("output {k}") }, true)?;
    }
    let desc = |f: &GpuFrame| Desc { format: f.format, width: f.width, height: f.height, premultiplied: f.color.premultiplied };
    let ins: Vec<Desc> = inputs.iter().map(desc).collect();
    let out_descs: Vec<Desc> = outs.iter().map(desc).collect();
    prepare(effects, topo, io, &ins, &out_descs, bypass, true)?;
    // The pooled textures stay borrowed until the caller submitted `enc`.
    let res = record_gpu(effects, topo, io, inputs, outs, info, enc);
    if res.is_err() {
        io.release();
    }
    res
}

fn record_gpu(
    effects: &mut [Effect],
    topo: &Topology,
    io: &mut FrameIo,
    inputs: &[GpuFrame],
    outs: &[GpuFrame],
    info: Option<&FrameInfo>,
    enc: &mut wgpu::CommandEncoder,
) -> Result<(), Error> {
    let bypass = info.is_none();
    let ctx = effects[0].program.ctx.clone();
    let (device, queue, conv) = (&ctx.device, &ctx.queue, &ctx.conv);
    if io.gpu_outputs.len() != outs.len()
        || io.gpu_outputs.iter().zip(outs.iter()).any(|(slot, o)| slot.key != (o.format, o.width, o.height))
    {
        io.gpu_outputs = outs.iter().map(|o| GpuOutputSlot::new(device, o.format, o.width, o.height)).collect();
        io.allocations += 1;
    }
    for (slot, f) in io.inputs.iter_mut().zip(inputs) {
        slot.use_gpu_frame(device, queue, conv, &f.planes, &f.color);
    }
    for (k, out) in outs.iter().enumerate() {
        let src = if bypass { Source::Input(topo.pad_of(topo.outputs[k])) } else { topo.outputs[k] };
        let tex = source_texture(effects, &io.inputs, src);
        io.gpu_outputs[k].bind(device, queue, conv, &tex, &out.planes, &out.color)?;
    }
    let mut cpass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor { label: Some("gpufx"), timestamp_writes: None });
    encode_effects(effects, topo, io, inputs.len(), info, &mut cpass);
    for slot in &io.gpu_outputs {
        slot.encode(conv, &mut cpass)?;
    }
    Ok(())
}

/// One `[in]...body[out]...` statement of a graph description.
struct NodeSpec<'a> {
    inputs: Vec<&'a str>,
    body: &'a str,
    outputs: Vec<&'a str>,
}

fn graph_err(msg: impl Into<String>) -> Error {
    Error::Graph(msg.into())
}

/// `[label]` lists at the start of `rest`, which is advanced past them.
fn parse_labels<'a>(rest: &mut &'a str, statement: &str) -> Result<Vec<&'a str>, Error> {
    let mut labels = Vec::new();
    loop {
        let s = rest.trim_start();
        let Some(inner) = s.strip_prefix('[') else {
            *rest = s;
            return Ok(labels);
        };
        let end = inner.find(']').ok_or_else(|| graph_err(format!("unclosed `[` in `{statement}`")))?;
        let label = inner[..end].trim();
        if label.is_empty() || !label.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
            return Err(graph_err(format!(
                "bad label `[{}]` in `{statement}`: use letters, digits, `_` or `-` (`.` would clash with `label.param`)",
                &inner[..end]
            )));
        }
        labels.push(label);
        *rest = &inner[end + 1..];
    }
}

fn parse_spec(text: &str) -> Result<Vec<NodeSpec<'_>>, Error> {
    let mut nodes = Vec::new();
    for statement in text.split(';').map(str::trim).filter(|s| !s.is_empty()) {
        let mut rest = statement;
        let inputs = parse_labels(&mut rest, statement)?;
        let end = rest.find('[').unwrap_or(rest.len());
        let body = rest[..end].trim();
        rest = &rest[end..];
        let outputs = parse_labels(&mut rest, statement)?;
        if !rest.trim().is_empty() {
            return Err(graph_err(format!("unexpected `{}` after the output labels of `{statement}`", rest.trim())));
        }
        if body.is_empty() {
            return Err(graph_err(format!("`{statement}` names no effect")));
        }
        if inputs.is_empty() {
            return Err(graph_err(format!("`{statement}` has no input label, e.g. `[0]{body}`")));
        }
        if outputs.is_empty() {
            return Err(graph_err(format!("`{statement}` has no output label, e.g. `{body}[out]`")));
        }
        nodes.push(NodeSpec { inputs, body, outputs });
    }
    if nodes.is_empty() {
        return Err(graph_err("the graph is empty"));
    }
    Ok(nodes)
}

/// The input pad a label names (`[0]`, `[1]`...), if it is a number.
fn pad_label(label: &str) -> Option<Result<usize, Error>> {
    if !label.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(match label.parse::<usize>() {
        Ok(i) if i.to_string() == label && i < 64 => Ok(i),
        _ => Err(graph_err(format!("input pad label `[{label}]`: write it as a number from 0 to 63 without leading zeros"))),
    })
}

enum NodeKind {
    /// `split` or `null`: the outputs are the input itself.
    Split,
    /// Effects of an `a.zip|b.zip` node, by index.
    Effects(Vec<usize>),
}

/// Effects wired as a directed acyclic graph and run in one GPU submission. Effects
/// write the size of their first input; edges stay on the GPU in pooled textures.
pub struct EffectGraph {
    effects: Vec<Effect>,
    labels: Vec<String>,
    topo: Topology,
    /// Pixel format each effect input from another effect sees, as two filters in a row
    /// would negotiate it (`None` for input pads). Frames stay RGBA on the GPU; only the
    /// rules are checked.
    links: Vec<Vec<Option<String>>>,
    input_names: Vec<String>,
    input_formats: Vec<Vec<String>>,
    output_names: Vec<String>,
    output_formats: Vec<Vec<String>>,
    /// Output label of each effect node of a graph and its effects, for `label.param`.
    nodes: Vec<(String, Vec<usize>)>,
    /// (effect, parameter) of every entry of `param_names`.
    params: Vec<(usize, usize)>,
    param_names: Vec<String>,
    /// "chain" or "graph", in messages.
    what: &'static str,
    io: FrameIo,
    /// Copies and the last submission of D3D12/D3D11 frames (see `d3d12.rs`).
    #[cfg(windows)]
    pub(crate) dx: crate::d3d12::GraphState,
}

impl EffectGraph {
    /// Builds a graph from its description:
    /// `[0]split[a][b]; [a]gaussian-blur.zip[ba]; [b]grayscale.zip|vignette.zip[gb]; [ba][gb]crossfade.zip[out]`.
    ///
    /// Statements are separated by `;`. Each reads labels, runs a node and names its
    /// outputs. `[0]`, `[1]`... are the input pads; every pad up to the highest must be
    /// read. Every other label is written once and read at most once (`split` it to read
    /// it twice); labels nobody reads are the outputs of the graph, in the order they are
    /// written. A node is `split` (any number of outputs, no copy), `null` (one output,
    /// no copy), or packages chained with `|`, which take as many labels as the first
    /// package has inputs and write one. `open` loads a package from its text and returns
    /// its parameter label (see [`EffectChain::new`]) and the effect.
    pub fn parse(text: &str, mut open: impl FnMut(&str) -> Result<(String, Effect), Error>) -> Result<Self, Error> {
        let specs = parse_spec(text)?;
        let mut producers: HashMap<&str, usize> = HashMap::new();
        let mut defined: Vec<&str> = Vec::new();
        let mut kinds = Vec::with_capacity(specs.len());
        let mut effects = Vec::new();
        let mut labels = Vec::new();
        for (n, spec) in specs.iter().enumerate() {
            for &label in &spec.outputs {
                if pad_label(label).is_some() {
                    return Err(graph_err(format!("`[{label}]` names an input pad; output labels must not be numbers")));
                }
                if producers.insert(label, n).is_some() {
                    return Err(graph_err(format!("label `[{label}]` is written twice")));
                }
                defined.push(label);
            }
            let (ins, outs) = (spec.inputs.len(), spec.outputs.len());
            let kind = match spec.body {
                "split" | "null" => {
                    if ins != 1 {
                        return Err(graph_err(format!("`{}` reads one label, got {ins}", spec.body)));
                    }
                    if spec.body == "null" && outs != 1 {
                        return Err(graph_err(format!("`null` writes one label, got {outs}")));
                    }
                    NodeKind::Split
                }
                body => {
                    if outs != 1 {
                        return Err(graph_err(format!("`{body}` writes one label, got {outs}; split it to use it twice")));
                    }
                    let mut ks = Vec::new();
                    for path in body.split('|').map(str::trim).filter(|p| !p.is_empty()) {
                        let (label, fx) = open(path)?;
                        let wanted = if ks.is_empty() { ins } else { 1 };
                        if fx.input_count() != wanted {
                            return Err(graph_err(if ks.is_empty() {
                                format!("`{path}` takes {} inputs, the node gives it {ins}", fx.input_count())
                            } else {
                                format!(
                                    "`{path}` takes {} inputs; only the first effect of `{body}` may take more than one",
                                    fx.input_count()
                                )
                            }));
                        }
                        ks.push(effects.len());
                        effects.push(fx);
                        labels.push(label);
                    }
                    if ks.is_empty() {
                        return Err(graph_err(format!("`{body}` names no package")));
                    }
                    NodeKind::Effects(ks)
                }
            };
            kinds.push(kind);
        }

        let mut readers: HashSet<&str> = HashSet::new();
        let mut nb_inputs = 0;
        for spec in &specs {
            for &label in &spec.inputs {
                match pad_label(label) {
                    Some(pad) => nb_inputs = nb_inputs.max(pad? + 1),
                    None if !producers.contains_key(label) => {
                        return Err(graph_err(format!("label `[{label}]` is read but never written")))
                    }
                    None => {}
                }
                if !readers.insert(label) {
                    return Err(graph_err(format!("label `[{label}]` is read twice; split it: `[{label}]split[{label}1][{label}2]`")));
                }
            }
        }
        if nb_inputs == 0 {
            return Err(graph_err("the graph reads no input pad (`[0]`)"));
        }
        if let Some(pad) = (0..nb_inputs).find(|p| !readers.contains(p.to_string().as_str())) {
            return Err(graph_err(format!("input pad `[{pad}]` is not read (pads [0] to [{}] must all be)", nb_inputs - 1)));
        }

        // Labels resolve to a pad or an effect; split and null are no node of their own.
        fn resolve(
            label: &str,
            specs: &[NodeSpec],
            producers: &HashMap<&str, usize>,
            kinds: &[NodeKind],
            depth: usize,
        ) -> Result<Source, Error> {
            if let Some(pad) = pad_label(label) {
                return Ok(Source::Input(pad?));
            }
            let n = producers[label];
            match &kinds[n] {
                NodeKind::Effects(ks) => Ok(Source::Node(*ks.last().expect("at least one"))),
                NodeKind::Split if depth > specs.len() => Err(graph_err(format!("the graph has a cycle through `[{label}]`"))),
                NodeKind::Split => resolve(specs[n].inputs[0], specs, producers, kinds, depth + 1),
            }
        }
        let mut node_inputs = vec![Vec::new(); effects.len()];
        let mut nodes = Vec::new();
        for (n, spec) in specs.iter().enumerate() {
            if let NodeKind::Effects(ks) = &kinds[n] {
                node_inputs[ks[0]] = spec.inputs.iter().map(|l| resolve(l, &specs, &producers, &kinds, 0)).collect::<Result<_, _>>()?;
                for w in ks.windows(2) {
                    node_inputs[w[1]] = vec![Source::Node(w[0])];
                }
                nodes.push((spec.outputs[0].to_string(), ks.clone()));
            }
        }
        let outputs: Vec<(String, Source)> = defined
            .iter()
            .filter(|l| !readers.contains(*l))
            .map(|l| Ok((l.to_string(), resolve(l, &specs, &producers, &kinds, 0)?)))
            .collect::<Result<_, Error>>()?;
        if outputs.is_empty() {
            return Err(graph_err("the graph has no output: every label it writes is read again"));
        }
        if effects.is_empty() {
            return Err(graph_err("the graph runs no effect"));
        }

        // Topological order (Kahn), in statement order among the ready effects.
        let mut order = Vec::with_capacity(effects.len());
        let mut done = vec![false; effects.len()];
        while order.len() < effects.len() {
            let ready = (0..effects.len()).find(|&k| {
                !done[k] && node_inputs[k].iter().all(|s| matches!(*s, Source::Input(_)) || matches!(*s, Source::Node(j) if done[j]))
            });
            let Some(k) = ready else {
                let stuck: Vec<String> =
                    nodes.iter().filter(|(_, ks)| ks.iter().any(|&k| !done[k])).map(|(l, _)| format!("[{l}]")).collect();
                return Err(graph_err(format!("the graph has a cycle through {}", stuck.join(", "))));
            };
            done[k] = true;
            order.push(k);
        }

        let topo = Topology { nb_inputs, node_inputs, order, outputs: outputs.iter().map(|o| o.1).collect() };
        let input_names = (0..nb_inputs).map(|i| format!("in{i}")).collect();
        let output_names = outputs.into_iter().map(|o| o.0).collect();
        Self::from_parts(effects.into_iter().zip(labels).map(|(fx, l)| (l, fx)).collect(), topo, input_names, output_names, nodes, "graph")
    }

    pub(crate) fn from_parts(
        effects: Vec<(String, Effect)>,
        topo: Topology,
        input_names: Vec<String>,
        output_names: Vec<String>,
        nodes: Vec<(String, Vec<usize>)>,
        what: &'static str,
    ) -> Result<Self, Error> {
        let (labels, effects): (Vec<String>, Vec<Effect>) = effects.into_iter().unzip();
        let ctx = &effects[0].program.ctx;
        for (k, fx) in effects.iter().enumerate() {
            if !Arc::ptr_eq(&fx.program.ctx, ctx) {
                return Err(Error::Unsupported(format!("effect {k} (`{}`) runs on another GPU device", labels[k])));
            }
        }
        // What gpufx=a,gpufx=b would negotiate: the first output format of `a` that `b` accepts.
        let mut links = Vec::with_capacity(effects.len());
        let mut input_formats: Vec<Option<Vec<String>>> = vec![None; topo.nb_inputs];
        for (k, fx) in effects.iter().enumerate() {
            let m = &fx.package().manifest;
            let mut row = Vec::new();
            for (i, src) in topo.node_inputs[k].iter().enumerate() {
                let accepted = &m.inputs[i].formats;
                match *src {
                    Source::Node(j) => {
                        let prev = &effects[j].package().manifest;
                        let link = prev.output.formats.iter().find(|f| accepted.is_empty() || accepted.contains(f)).ok_or_else(|| {
                            Error::Unsupported(format!(
                                "`{}` outputs {} but `{}` accepts {}",
                                labels[j],
                                prev.output.formats.join(", "),
                                labels[k],
                                accepted.join(", ")
                            ))
                        })?;
                        row.push(Some(link.clone()));
                    }
                    Source::Input(p) => {
                        // A pad read by several effects takes the formats all of them accept.
                        let merged = match (&input_formats[p], accepted.is_empty()) {
                            (None, _) => accepted.clone(),
                            (Some(have), true) => have.clone(),
                            (Some(have), false) if have.is_empty() => accepted.clone(),
                            (Some(have), false) => {
                                let common: Vec<String> = have.iter().filter(|f| accepted.contains(f)).cloned().collect();
                                if common.is_empty() {
                                    return Err(Error::Unsupported(format!(
                                        "input {p} is read by effects accepting {} and by `{}` accepting {}: no common format",
                                        have.join(", "),
                                        labels[k],
                                        accepted.join(", ")
                                    )));
                                }
                                common
                            }
                        };
                        input_formats[p] = Some(merged);
                        row.push(None);
                    }
                }
            }
            links.push(row);
        }
        let input_formats = input_formats.into_iter().map(Option::unwrap_or_default).collect();
        let output_formats = topo
            .outputs
            .iter()
            .map(|s| match *s {
                Source::Node(j) => effects[j].package().manifest.output.formats.clone(),
                Source::Input(_) => crate::manifest::default_output_formats(),
            })
            .collect();

        let mut params = Vec::new();
        let mut param_names = Vec::new();
        for (k, fx) in effects.iter().enumerate() {
            for (i, def) in fx.params.defs().iter().enumerate() {
                params.push((k, i));
                param_names.push(if effects.len() == 1 {
                    def.name.clone()
                } else if labels.iter().filter(|l| **l == labels[k]).count() == 1 && labels[k].parse::<usize>().is_err() {
                    format!("{}.{}", labels[k], def.name)
                } else {
                    format!("{k}.{}", def.name)
                });
            }
        }
        Ok(EffectGraph {
            effects,
            labels,
            topo,
            links,
            input_names,
            input_formats,
            output_names,
            output_formats,
            nodes,
            params,
            param_names,
            what,
            io: FrameIo::default(),
            #[cfg(windows)]
            dx: Default::default(),
        })
    }

    /// Effects in the order they were given (statement order for a parsed graph).
    pub fn effects(&self) -> &[Effect] {
        &self.effects
    }

    pub fn labels(&self) -> &[String] {
        &self.labels
    }

    /// Where every input of effect `k` comes from.
    pub fn effect_inputs(&self, k: usize) -> &[Source] {
        &self.topo.node_inputs[k]
    }

    /// Effects in execution order.
    pub fn order(&self) -> &[usize] {
        &self.topo.order
    }

    pub fn input_count(&self) -> usize {
        self.topo.nb_inputs
    }

    /// Names of the input pads: `in0`, `in1`... for a graph, the manifest input names of
    /// the first effect for a chain.
    pub fn input_names(&self) -> &[String] {
        &self.input_names
    }

    /// Pixel formats input pad `i` accepts: those every effect reading it accepts. Empty
    /// accepts anything.
    pub fn input_formats(&self, i: usize) -> &[String] {
        &self.input_formats[i]
    }

    pub fn output_count(&self) -> usize {
        self.topo.outputs.len()
    }

    /// Labels of the outputs, in the order they are written.
    pub fn output_names(&self) -> &[String] {
        &self.output_names
    }

    /// Pixel formats output `k` may have, in order of preference.
    pub fn output_formats(&self, k: usize) -> &[String] {
        &self.output_formats[k]
    }

    pub fn output_source(&self, k: usize) -> Source {
        self.topo.outputs[k]
    }

    /// The input pad whose size (and, in FFmpeg, frame rate and aspect ratio) output `k`
    /// has: effects write the size of their first input.
    pub fn output_pad(&self, k: usize) -> usize {
        self.topo.pad_of(self.topo.outputs[k])
    }

    /// Full names of every parameter: `name` for a single effect, else `label.name`, or
    /// `index.name` when two effects share a label.
    pub fn param_names(&self) -> &[String] {
        &self.param_names
    }

    /// Finds a parameter by its full name, by `label.name`, by `index.name` (0 based), by
    /// `node.name` where node is the output label of a graph node (`[ba]`), or, when only
    /// one effect has it, by its bare name. A prefix made of digits is always an index.
    pub fn find_param(&self, name: &str) -> Result<usize, Error> {
        if let Some(i) = self.param_names.iter().position(|n| n == name) {
            return Ok(i);
        }
        let find = |k: usize, param: &str| self.params.iter().position(|&(e, p)| e == k && self.effects[e].params.defs()[p].name == param);
        if let Some((prefix, param)) = name.split_once('.') {
            let what = self.what;
            let effects: Vec<usize> = match prefix.parse::<usize>() {
                Ok(k) if k < self.effects.len() => vec![k],
                Ok(_) => Vec::new(),
                Err(_) => {
                    let matches: Vec<usize> = (0..self.labels.len()).filter(|&k| self.labels[k] == prefix).collect();
                    if matches.len() > 1 {
                        return Err(Error::Param(format!(
                            "`{prefix}` names {} effects of the {what}; use the index, e.g. `{}.{param}`",
                            matches.len(),
                            matches[0]
                        )));
                    }
                    if matches.is_empty() {
                        self.nodes.iter().find(|(l, _)| l == prefix).map(|(_, ks)| ks.clone()).unwrap_or_default()
                    } else {
                        matches
                    }
                }
            };
            if effects.is_empty() {
                let mut known = self.labels.clone();
                known.extend(self.nodes.iter().map(|(l, _)| l.clone()));
                return Err(Error::Param(format!("the {what} has no effect `{prefix}` (effects: {})", known.join(", "))));
            }
            let owners: Vec<usize> = effects.iter().filter_map(|&k| find(k, param)).collect();
            return match owners.as_slice() {
                [i] => Ok(*i),
                [] if effects.len() == 1 => Err(Error::Param(format!("effect `{}` has no parameter `{param}`", self.labels[effects[0]]))),
                [] => Err(Error::Param(format!("node `{prefix}` has no parameter `{param}`"))),
                _ => Err(Error::Param(format!(
                    "several effects of node `{prefix}` have a parameter `{param}`: {}",
                    owners.iter().map(|&i| self.param_names[i].as_str()).collect::<Vec<_>>().join(", ")
                ))),
            };
        }
        let owners: Vec<usize> = (0..self.effects.len()).filter_map(|k| find(k, name)).collect();
        match owners.as_slice() {
            [i] => Ok(*i),
            [] => Err(Error::Param(format!("no effect of the {} has a parameter `{name}`", self.what))),
            _ => Err(Error::Param(format!(
                "several effects have a parameter `{name}`: {}",
                owners.iter().map(|&i| self.param_names[i].as_str()).collect::<Vec<_>>().join(", ")
            ))),
        }
    }

    /// Parameter `index` of `param_names` as (block, name inside its effect).
    fn param(&mut self, index: usize) -> Result<(&mut ParamBlock, String), Error> {
        let &(k, p) = self.params.get(index).ok_or_else(|| Error::Param(format!("no parameter {index}")))?;
        let block = &mut self.effects[k].params;
        let name = block.defs()[p].name.clone();
        Ok((block, name))
    }

    /// Sets a parameter (any name `find_param` takes) from text.
    pub fn set_param_str(&mut self, name: &str, text: &str) -> Result<(), Error> {
        let index = self.find_param(name)?;
        let (block, name) = self.param(index)?;
        block.set_str(&name, text)?;
        // An expression is compiled now, so a bad one fails here (sendcmd) and not mid-stream.
        if block.expr(&name).is_some() {
            let k = self.params[index].0;
            self.effects[k].sync_exprs()?;
        }
        Ok(())
    }

    /// Sets the first components of a parameter (any name `find_param` takes).
    pub fn set_param(&mut self, name: &str, values: &[f64]) -> Result<(), Error> {
        let (block, name) = self.param(self.find_param(name)?)?;
        block.set(&name, values)
    }

    /// Checks one stream per input pad against the rules of every effect: an effect
    /// reading another sees that effect's size (the size of its first input) and the
    /// format negotiated between them.
    pub fn check_inputs(&self, streams: &[StreamInfo]) -> Result<(), Error> {
        if streams.len() != self.topo.nb_inputs {
            return Err(Error::Unsupported(format!("the {} takes {} input(s), got {}", self.what, self.topo.nb_inputs, streams.len())));
        }
        check_nodes(&self.effects, &self.topo, Some(&self.links), streams)
    }

    /// GPU memory the graph would hold for these input pad sizes, without allocating it:
    /// the pooled pass textures (the peak number alive at once) and their bytes.
    /// `deep`: frames above 8 bits (`rgba16float` textures).
    pub fn memory_plan(&self, sizes: &[(u32, u32)], deep: bool) -> Result<(usize, u64), Error> {
        if sizes.len() != self.topo.nb_inputs {
            return Err(Error::Unsupported(format!("the {} takes {} input(s), got {}", self.what, self.topo.nb_inputs, sizes.len())));
        }
        let (_, mips) = mip_sources(&self.effects, &self.topo);
        let plan = plan(&self.effects, &self.topo, &self.topo.node_sizes(sizes), &mips, deep)?;
        Ok((plan.slots.len(), plan.bytes(deep)))
    }

    /// GPU memory held for the current frames; zero before the first one.
    pub fn memory(&self) -> MemoryStats {
        self.io.memory
    }

    /// Runs the graph on RGBA8 images, one per input pad, writing one image per output.
    pub fn process(&mut self, inputs: &[Image], outs: Vec<ImageMut>, info: &FrameInfo) -> Result<(), Error> {
        let frames: Vec<Frame> = inputs.iter().map(|&i| i.into()).collect();
        let mut outs: Vec<FrameMut> = outs.into_iter().map(Into::into).collect();
        self.process_frames(&frames, &mut outs, info)
    }

    /// Runs the graph on frames in any [`PixelFormat`], converted on the GPU. Output `k`
    /// must have the size of input [`EffectGraph::output_pad`]`(k)`.
    pub fn process_frames(&mut self, inputs: &[Frame], outs: &mut [FrameMut], info: &FrameInfo) -> Result<(), Error> {
        run(&mut self.effects, &self.topo, &mut self.io, inputs, outs, Some(info))
    }

    /// Writes every output without running the effects, as a disabled filter: output `k`
    /// is input [`EffectGraph::output_pad`]`(k)` converted to its format. `inputs` may
    /// hold only the first pads, as long as every output's pad is given.
    pub fn convert(&mut self, inputs: &[Frame], outs: &mut [FrameMut]) -> Result<(), Error> {
        run(&mut self.effects, &self.topo, &mut self.io, inputs, outs, None)
    }

    /// Runs the graph on frames already on the GPU (textures of this graph's device),
    /// recording every pass into `enc`. Nothing is submitted: the caller submits `enc`
    /// (and synchronises with whoever else uses the textures) before the next call, which
    /// rewrites the uniforms. Output `k` must have the size of input
    /// [`EffectGraph::output_pad`]`(k)`. Without `info` the effects are bypassed as in
    /// [`EffectGraph::convert`]. Bind groups of the frame textures are made per call
    /// (the textures of a frame pool change from frame to frame); the pooled textures
    /// are reused as for CPU frames. They are borrowed from the context pool until
    /// [`EffectGraph::release_frame`] or the next call: call it right after submitting
    /// `enc`, so other graphs on the device can use them.
    pub fn encode_gpu(
        &mut self,
        inputs: &[GpuFrame],
        outs: &[GpuFrame],
        info: Option<&FrameInfo>,
        enc: &mut wgpu::CommandEncoder,
    ) -> Result<(), Error> {
        run_gpu(&mut self.effects, &self.topo, &mut self.io, inputs, outs, info, enc)
    }

    /// Gives the pooled textures of the last [`EffectGraph::encode_gpu`] back to the
    /// context pool. Only once its encoder was submitted (or dropped): later submissions
    /// of other graphs reuse them.
    pub fn release_frame(&mut self) {
        self.io.release();
    }

    /// The device the graph runs on.
    pub fn context(&self) -> &Arc<crate::GpuContext> {
        self.effects[0].program.context()
    }

    /// Copies the parameter values of `other`, a graph opened from the same description
    /// (on another device, say).
    pub fn copy_params_from(&mut self, other: &EffectGraph) -> Result<(), Error> {
        if self.effects.len() != other.effects.len() || self.param_names != other.param_names {
            return Err(Error::Param("the graphs differ".into()));
        }
        for (a, b) in self.effects.iter_mut().zip(&other.effects) {
            a.params = b.params.clone();
        }
        Ok(())
    }

    /// How many times frame textures, buffers or bind groups were (re)made: once per new
    /// size or format, never per frame. For tests and diagnostics.
    pub fn allocations(&self) -> usize {
        self.io.allocations
    }
}

/// Effects run one after the other in one GPU submission, as if each fed the next
/// through its own filter, without the round trip to CPU memory in between. A linear
/// [`EffectGraph`].
pub struct EffectChain {
    graph: EffectGraph,
}

impl EffectChain {
    /// `effects` pairs a label (the package file name, used in parameter names such as
    /// `vignette.strength`) with an effect. All effects must share one GPU context.
    pub fn new(effects: Vec<(String, Effect)>) -> Result<Self, Error> {
        if effects.is_empty() {
            return Err(Error::Unsupported("a chain needs at least one effect".into()));
        }
        let ctx = effects[0].1.program.ctx.clone();
        for (k, (label, fx)) in effects.iter().enumerate().skip(1) {
            if !Arc::ptr_eq(&fx.program.ctx, &ctx) {
                return Err(Error::Unsupported(format!("effect {k} (`{label}`) runs on another GPU device")));
            }
            if fx.input_count() != 1 {
                return Err(Error::Unsupported(format!(
                    "effect {k} (`{label}`) takes {} inputs; only the first effect of a chain may take more than one",
                    fx.input_count()
                )));
            }
        }
        let first = &effects[0].1;
        let nb_inputs = first.input_count();
        let input_names = first.package().manifest.inputs.iter().map(|d| d.name.clone()).collect();
        let n = effects.len();
        let mut node_inputs = vec![(0..nb_inputs).map(Source::Input).collect::<Vec<_>>()];
        node_inputs.extend((1..n).map(|k| vec![Source::Node(k - 1)]));
        let topo = Topology { nb_inputs, node_inputs, order: (0..n).collect(), outputs: vec![Source::Node(n - 1)] };
        let graph = EffectGraph::from_parts(effects, topo, input_names, vec!["default".into()], Vec::new(), "chain")?;
        Ok(EffectChain { graph })
    }

    /// The chain as the graph it is.
    pub fn graph(&self) -> &EffectGraph {
        &self.graph
    }

    pub fn into_graph(self) -> EffectGraph {
        self.graph
    }

    pub fn effects(&self) -> &[Effect] {
        self.graph.effects()
    }

    pub fn labels(&self) -> &[String] {
        self.graph.labels()
    }

    /// The first effect: its inputs are the inputs of the chain.
    pub fn first(&self) -> &Effect {
        &self.graph.effects[0]
    }

    /// The last effect: its output rules are those of the chain.
    pub fn last(&self) -> &Effect {
        self.graph.effects.last().expect("at least one effect")
    }

    /// See [`EffectGraph::param_names`].
    pub fn param_names(&self) -> &[String] {
        self.graph.param_names()
    }

    /// See [`EffectGraph::find_param`]; a package named `2.zip` is reached by its index only.
    pub fn find_param(&self, name: &str) -> Result<usize, Error> {
        self.graph.find_param(name)
    }

    pub fn set_param_str(&mut self, name: &str, text: &str) -> Result<(), Error> {
        self.graph.set_param_str(name, text)
    }

    pub fn set_param(&mut self, name: &str, values: &[f64]) -> Result<(), Error> {
        self.graph.set_param(name, values)
    }

    /// Checks one stream per input of the first effect against the rules of every effect:
    /// later effects see the first stream's size and the format negotiated in `new`.
    pub fn check_inputs(&self, streams: &[StreamInfo]) -> Result<(), Error> {
        if streams.len() != self.graph.input_count() {
            return self.first().package().manifest.check_inputs(streams);
        }
        self.graph.check_inputs(streams)
    }

    /// Runs every effect on `inputs` (one per input of the first effect) and writes the
    /// RGBA result of the last one into `out`, which has the size of `inputs[0]`.
    pub fn process(&mut self, inputs: &[Image], out: ImageMut, info: &FrameInfo) -> Result<(), Error> {
        self.graph.process(inputs, vec![out], info)
    }

    /// [`EffectChain::process`] for frames in any [`PixelFormat`], converted on the GPU.
    pub fn process_frames(&mut self, inputs: &[Frame], out: FrameMut, info: &FrameInfo) -> Result<(), Error> {
        self.graph.process_frames(inputs, &mut [out], info)
    }

    /// See [`EffectGraph::allocations`].
    pub fn allocations(&self) -> usize {
        self.graph.allocations()
    }

    /// See [`EffectGraph::memory`].
    pub fn memory(&self) -> MemoryStats {
        self.graph.memory()
    }

    /// Converts `input` (in place of input 0) to the format of `out` without running the
    /// effects, as a disabled filter passes its first input through.
    pub fn convert(&mut self, input: &Frame, out: FrameMut) -> Result<(), Error> {
        self.graph.convert(std::slice::from_ref(input), &mut [out])
    }
}
