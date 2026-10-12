//! Frames in CPU memory: the pixel formats the runtime converts to and from RGBA on the
//! GPU, and the colour properties the conversion needs.

use crate::runtime::{Image, ImageMut};
use crate::Error;

/// Pixel formats effects read and write directly. Everything but straight `rgba` input is
/// converted on the GPU, so effects always see RGBA. Names are FFmpeg's; samples of more
/// than 8 bits are little endian, as FFmpeg stores them on little endian machines.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PixelFormat {
    /// 8-bit RGBA, `rgba`.
    Rgba,
    /// 16-bit RGBA, `rgba64le`.
    Rgba64,
    /// 8-bit Y plane and an interleaved half size UV plane.
    Nv12,
    /// Like NV12 with 10-bit samples in the high bits of 16 (`p010le`).
    P010,
    Yuv420p,
    Yuv422p,
    Yuv444p,
    /// 10-bit samples in the low bits of 16 (`yuv420p10le`).
    Yuv420p10,
    Yuv422p10,
    Yuv444p10,
    /// `yuv420p` with a full size alpha plane.
    Yuva420p,
    Yuva444p,
}

/// Every format with its FFmpeg name. `yuvj*` names are accepted as aliases (the range
/// comes with the colour info).
const NAMES: [(PixelFormat, &str); 12] = [
    (PixelFormat::Rgba, "rgba"),
    (PixelFormat::Rgba64, "rgba64le"),
    (PixelFormat::Nv12, "nv12"),
    (PixelFormat::P010, "p010le"),
    (PixelFormat::Yuv420p, "yuv420p"),
    (PixelFormat::Yuv422p, "yuv422p"),
    (PixelFormat::Yuv444p, "yuv444p"),
    (PixelFormat::Yuv420p10, "yuv420p10le"),
    (PixelFormat::Yuv422p10, "yuv422p10le"),
    (PixelFormat::Yuv444p10, "yuv444p10le"),
    (PixelFormat::Yuva420p, "yuva420p"),
    (PixelFormat::Yuva444p, "yuva444p"),
];

/// How the samples of a format are stored, as the conversion shader reads them.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Layout {
    pub kind: PlaneKind,
    /// Bits of a sample value.
    pub depth: u32,
    /// Values are stored shifted left by this much (6 for P010).
    pub shift: u32,
    /// Bytes per stored sample: 1 or 2.
    pub bytes: u32,
    /// Chroma subsampling factors (1 or 2).
    pub sub: (u32, u32),
    /// A fourth plane holds alpha.
    pub alpha: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PlaneKind {
    /// One plane of interleaved RGBA.
    Rgba = 0,
    /// Y plane, then interleaved UV.
    SemiPlanar = 1,
    /// Y, U, V planes (and alpha).
    Planar = 2,
}

impl PixelFormat {
    pub const ALL: [PixelFormat; 12] = {
        let mut all = [PixelFormat::Rgba; 12];
        let mut i = 0;
        while i < NAMES.len() {
            all[i] = NAMES[i].0;
            i += 1;
        }
        all
    };

    /// The format of an FFmpeg pixel format name, if the runtime converts it.
    pub fn from_name(name: &str) -> Option<Self> {
        let name = match name {
            "yuvj420p" => "yuv420p",
            "yuvj422p" => "yuv422p",
            "yuvj444p" => "yuv444p",
            n => n,
        };
        NAMES.iter().find(|(_, n)| *n == name).map(|&(f, _)| f)
    }

    /// FFmpeg name, e.g. `p010le`.
    pub fn name(self) -> &'static str {
        NAMES.iter().find(|(f, _)| *f == self).map(|&(_, n)| n).expect("every format has a name")
    }

    pub fn is_rgb(self) -> bool {
        matches!(self, PixelFormat::Rgba | PixelFormat::Rgba64)
    }

    pub fn has_alpha(self) -> bool {
        self.is_rgb() || self.layout().alpha
    }

    pub(crate) fn layout(self) -> Layout {
        use PixelFormat::*;
        let (kind, depth, shift, sub, alpha) = match self {
            Rgba => (PlaneKind::Rgba, 8, 0, (1, 1), true),
            Rgba64 => (PlaneKind::Rgba, 16, 0, (1, 1), true),
            Nv12 => (PlaneKind::SemiPlanar, 8, 0, (2, 2), false),
            P010 => (PlaneKind::SemiPlanar, 10, 6, (2, 2), false),
            Yuv420p => (PlaneKind::Planar, 8, 0, (2, 2), false),
            Yuv422p => (PlaneKind::Planar, 8, 0, (2, 1), false),
            Yuv444p => (PlaneKind::Planar, 8, 0, (1, 1), false),
            Yuv420p10 => (PlaneKind::Planar, 10, 0, (2, 2), false),
            Yuv422p10 => (PlaneKind::Planar, 10, 0, (2, 1), false),
            Yuv444p10 => (PlaneKind::Planar, 10, 0, (1, 1), false),
            Yuva420p => (PlaneKind::Planar, 8, 0, (2, 2), true),
            Yuva444p => (PlaneKind::Planar, 8, 0, (1, 1), true),
        };
        let bytes = if depth + shift > 8 { 2 } else { 1 };
        // The RGBA plane carries its alpha itself, not in a fourth plane.
        Layout { kind, depth, shift, bytes, sub, alpha: alpha && kind == PlaneKind::Planar }
    }

    pub fn plane_count(self) -> usize {
        let l = self.layout();
        match l.kind {
            PlaneKind::Rgba => 1,
            PlaneKind::SemiPlanar => 2,
            PlaneKind::Planar => 3 + l.alpha as usize,
        }
    }

    /// Samples per row, rows and interleaved channels of plane `plane` of a `w` x `h` frame.
    pub(crate) fn plane_dims(self, plane: usize, w: u32, h: u32) -> (u32, u32, u32) {
        let l = self.layout();
        let chroma = plane == 1 || (plane == 2 && l.kind == PlaneKind::Planar);
        let (pw, ph) = if chroma { (w.div_ceil(l.sub.0), h.div_ceil(l.sub.1)) } else { (w, h) };
        let channels = match (l.kind, plane) {
            (PlaneKind::Rgba, _) => 4,
            (PlaneKind::SemiPlanar, 1) => 2,
            _ => 1,
        };
        (pw, ph, channels)
    }

    /// Bytes of one row and number of rows of plane `plane` of a `w` x `h` frame.
    pub fn plane_size(self, plane: usize, w: u32, h: u32) -> (u32, u32) {
        let (pw, ph, channels) = self.plane_dims(plane, w, h);
        (pw * channels * self.layout().bytes, ph)
    }
}

/// YUV to RGB matrix. Unused for RGB formats.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Matrix {
    /// BT.601 (also BT.470BG, SMPTE 170M), what FFmpeg assumes when unknown.
    #[default]
    Bt601,
    Bt709,
    /// BT.2020 non-constant luminance.
    Bt2020,
}

impl Matrix {
    /// Luma weights (Kr, Kb).
    pub(crate) fn kr_kb(self) -> (f32, f32) {
        match self {
            Matrix::Bt601 => (0.299, 0.114),
            Matrix::Bt709 => (0.2126, 0.0722),
            Matrix::Bt2020 => (0.2627, 0.0593),
        }
    }
}

/// Range of YUV samples. RGB and alpha are always full range.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Range {
    /// "TV" range: luma 16..235, chroma 16..240 (scaled for more bits).
    #[default]
    Limited,
    /// "PC"/JPEG range: 0..2^bits-1.
    Full,
}

/// Where chroma samples sit relative to the luma samples of a subsampled format.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ChromaLocation {
    /// Co-sited with the left luma column, centred vertically (MPEG-2, H.264 default).
    #[default]
    Left,
    /// Centred between the luma samples (MPEG-1, JPEG).
    Center,
    TopLeft,
    Top,
    BottomLeft,
    Bottom,
}

impl ChromaLocation {
    /// Horizontal and vertical position of a chroma sample inside the block of luma
    /// samples it covers: 0 on the first, 0.5 in the middle, 1 on the last.
    pub(crate) fn siting(self) -> (f32, f32) {
        match self {
            ChromaLocation::Left => (0.0, 0.5),
            ChromaLocation::Center => (0.5, 0.5),
            ChromaLocation::TopLeft => (0.0, 0.0),
            ChromaLocation::Top => (0.5, 0.0),
            ChromaLocation::BottomLeft => (0.0, 1.0),
            ChromaLocation::Bottom => (0.5, 1.0),
        }
    }
}

/// Colour properties of a frame. Effects see straight alpha: premultiplied frames are
/// divided by alpha after reading and multiplied again before writing (in RGB, so
/// premultiplied YUV is `(Y - black) * a + black` and `(C - mid) * a + mid`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ColorInfo {
    pub matrix: Matrix,
    pub range: Range,
    pub chroma_location: ChromaLocation,
    pub premultiplied: bool,
}

/// A frame in CPU memory, one slice and row stride per plane (unused planes are empty).
#[derive(Debug, Clone, Copy)]
pub struct Frame<'a> {
    pub format: PixelFormat,
    pub width: u32,
    pub height: u32,
    pub planes: [&'a [u8]; 4],
    /// Bytes per row of each plane.
    pub strides: [u32; 4],
    pub color: ColorInfo,
}

/// Where an effect writes its result, in any [`PixelFormat`].
#[derive(Debug)]
pub struct FrameMut<'a> {
    pub format: PixelFormat,
    pub width: u32,
    pub height: u32,
    pub planes: [&'a mut [u8]; 4],
    pub strides: [u32; 4],
    pub color: ColorInfo,
}

impl<'a> From<Image<'a>> for Frame<'a> {
    fn from(img: Image<'a>) -> Self {
        Frame {
            format: PixelFormat::Rgba,
            width: img.width,
            height: img.height,
            planes: [img.data, &[], &[], &[]],
            strides: [img.stride, 0, 0, 0],
            color: ColorInfo::default(),
        }
    }
}

impl<'a> From<ImageMut<'a>> for FrameMut<'a> {
    fn from(img: ImageMut<'a>) -> Self {
        FrameMut {
            format: PixelFormat::Rgba,
            width: img.width,
            height: img.height,
            planes: [img.data, &mut [], &mut [], &mut []],
            strides: [img.stride, 0, 0, 0],
            color: ColorInfo::default(),
        }
    }
}

/// A frame already in GPU memory, on the device of the effect that reads or writes it:
/// one texture per plane, in the FFmpeg plane order, each of
/// [`PixelFormat::plane_texture_format`] and [`PixelFormat::plane_texture_size`].
/// Inputs need `TEXTURE_BINDING` usage, outputs `STORAGE_BINDING`.
#[derive(Debug, Clone)]
pub struct GpuFrame {
    pub format: PixelFormat,
    pub width: u32,
    pub height: u32,
    pub planes: Vec<wgpu::Texture>,
    pub color: ColorInfo,
}

impl PixelFormat {
    /// Texture format of plane `plane` of a [`GpuFrame`]: the unorm format holding its
    /// samples as stored (`r8unorm`, `rg8unorm`, `rgba8unorm`, or the 16-bit versions,
    /// which need `Features::TEXTURE_FORMAT_16BIT_NORM`). Also how FFmpeg's Vulkan frames
    /// store each plane when every plane is its own image.
    pub fn plane_texture_format(self, plane: usize) -> wgpu::TextureFormat {
        use wgpu::TextureFormat as T;
        let (_, _, channels) = self.plane_dims(plane, 1, 1);
        match (channels, self.layout().bytes) {
            (4, 1) => T::Rgba8Unorm,
            (4, _) => T::Rgba16Unorm,
            (2, 1) => T::Rg8Unorm,
            (2, _) => T::Rg16Unorm,
            (_, 1) => T::R8Unorm,
            _ => T::R16Unorm,
        }
    }

    /// Width and height in texels of plane `plane` of a `w` x `h` frame.
    pub fn plane_texture_size(self, plane: usize, w: u32, h: u32) -> (u32, u32) {
        let (pw, ph, _) = self.plane_dims(plane, w, h);
        (pw, ph)
    }
}

impl GpuFrame {
    /// Checks the planes against the format; `output`: written by the effect.
    pub(crate) fn check(&self, what: &str, output: bool) -> Result<(), Error> {
        let (w, h) = (self.width, self.height);
        if w == 0 || h == 0 {
            return Err(Error::Frame(format!("{what}: empty {w}x{h} frame")));
        }
        let n = self.format.plane_count();
        if self.planes.len() != n {
            return Err(Error::Frame(format!(
                "{what}: a {} frame has {n} plane(s), got {} texture(s)",
                self.format.name(),
                self.planes.len()
            )));
        }
        let usage = if output { wgpu::TextureUsages::STORAGE_BINDING } else { wgpu::TextureUsages::TEXTURE_BINDING };
        for (p, t) in self.planes.iter().enumerate() {
            let (pw, ph) = self.format.plane_texture_size(p, w, h);
            let format = self.format.plane_texture_format(p);
            if t.width() != pw || t.height() != ph || t.format() != format || !t.usage().contains(usage) {
                return Err(Error::Frame(format!(
                    "{what}: plane {p} of a {w}x{h} {} frame must be a {pw}x{ph} {format:?} texture with {usage:?} usage, got {}x{} {:?} with {:?}",
                    self.format.name(),
                    t.width(),
                    t.height(),
                    t.format(),
                    t.usage()
                )));
            }
        }
        Ok(())
    }
}

/// Checks that every plane of a `format` frame fits its slice.
pub(crate) fn check_planes(what: &str, format: PixelFormat, w: u32, h: u32, lens: [usize; 4], strides: [u32; 4]) -> Result<(), Error> {
    if w == 0 || h == 0 {
        return Err(Error::Frame(format!("{what}: empty {w}x{h} frame")));
    }
    for p in 0..format.plane_count() {
        let (row, rows) = format.plane_size(p, w, h);
        let need = (rows as u64 - 1) * strides[p] as u64 + row as u64;
        if strides[p] < row || (lens[p] as u64) < need {
            return Err(Error::Frame(format!(
                "{what}: plane {p} of a {w}x{h} {} frame needs {row} bytes per row and {need} bytes, got stride {} and {} bytes",
                format.name(),
                strides[p],
                lens[p]
            )));
        }
    }
    Ok(())
}

impl Frame<'_> {
    pub(crate) fn check(&self, what: &str) -> Result<(), Error> {
        check_planes(what, self.format, self.width, self.height, self.planes.map(|p| p.len()), self.strides)
    }
}

impl FrameMut<'_> {
    pub(crate) fn check(&self, what: &str) -> Result<(), Error> {
        let lens = [self.planes[0].len(), self.planes[1].len(), self.planes[2].len(), self.planes[3].len()];
        check_planes(what, self.format, self.width, self.height, lens, self.strides)
    }
}
