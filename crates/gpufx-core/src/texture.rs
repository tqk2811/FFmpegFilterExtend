//! Package images (`manifest.textures`): size checks, decoding, atlas cutting,
//! premultiplied alpha and CPU mip chains, before the upload in `Program::new`.

use std::io::Cursor;

use image::{ImageReader, Limits, RgbaImage};

use crate::manifest::{TextureDef, MAX_TEXTURE_SIDE};
use crate::package::Package;
use crate::Error;

/// Decoded texels a package may hold in all (256 MiB of RGBA8), mip chains excluded.
pub const MAX_PACKAGE_TEXELS: u64 = 64 << 20;

/// The decoded texels of one texture: every mip level holds all layers, one after the other.
pub(crate) struct Texels {
    pub width: u32,
    pub height: u32,
    pub layers: u32,
    /// A `texture_2d_array` (even with one layer), else a `texture_2d`.
    pub array: bool,
    pub levels: Vec<Vec<u8>>,
}

fn reader(bytes: &[u8]) -> Result<ImageReader<Cursor<&[u8]>>, std::io::Error> {
    let mut r = ImageReader::new(Cursor::new(bytes)).with_guessed_format()?;
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_TEXTURE_SIDE);
    limits.max_image_height = Some(MAX_TEXTURE_SIDE);
    // A small PNG can claim a huge image: cap what the decoder may allocate.
    limits.max_alloc = Some(MAX_PACKAGE_TEXELS * 4);
    r.limits(limits);
    Ok(r)
}

fn dimensions(pkg: &Package, path: &str) -> Result<(u32, u32), Error> {
    let fail = |e: String| Error::Package(format!("texture `{path}`: {e} (images may be at most {MAX_TEXTURE_SIDE} pixels a side)"));
    let (w, h) = reader(pkg.file(path)?).map_err(|e| fail(e.to_string()))?.into_dimensions().map_err(|e| fail(e.to_string()))?;
    if w == 0 || h == 0 || w > MAX_TEXTURE_SIDE || h > MAX_TEXTURE_SIDE {
        return Err(fail(format!("{w}x{h} is too large")));
    }
    Ok((w, h))
}

/// Size of the texture `def` makes (width, height, layers), from the image headers only.
fn texture_size(pkg: &Package, def: &TextureDef) -> Result<(u32, u32, u32), Error> {
    let files = def.files();
    let (w, h) = dimensions(pkg, files[0])?;
    for f in &files[1..] {
        let d = dimensions(pkg, f)?;
        if d != (w, h) {
            return Err(Error::Package(format!(
                "texture `{}`: layer `{f}` is {}x{}, the first layer `{}` is {w}x{h}; layers must have one size",
                def.name, d.0, d.1, files[0]
            )));
        }
    }
    match def.grid {
        Some([c, r]) => {
            if !w.is_multiple_of(c) || !h.is_multiple_of(r) {
                return Err(Error::Package(format!("texture `{}`: {w}x{h} does not divide into a {c}x{r} grid", def.name)));
            }
            Ok((w / c, h / r, def.layer_count().expect("grid")))
        }
        None => Ok((w, h, files.len() as u32)),
    }
}

/// Checks every package image against the size limits without decoding it: each side at
/// most [`MAX_TEXTURE_SIDE`], layers of one size, grids that divide the atlas, and at most
/// [`MAX_PACKAGE_TEXELS`] texels in all.
pub(crate) fn check_package(pkg: &Package) -> Result<(), Error> {
    let mut total = 0u64;
    for def in &pkg.manifest.textures {
        let (w, h, layers) = texture_size(pkg, def)?;
        // An atlas decodes whole, even when `count` leaves cells out.
        total += match def.grid {
            Some([c, r]) => w as u64 * c as u64 * h as u64 * r as u64,
            None => w as u64 * h as u64 * layers as u64,
        };
        if total > MAX_PACKAGE_TEXELS {
            return Err(Error::Package(format!("textures decode to more than {MAX_PACKAGE_TEXELS} texels (texture `{}`)", def.name)));
        }
    }
    Ok(())
}

/// The one place colours of package images are changed: premultiplied alpha, rounded.
/// (A future linear `colorspace` must convert before this.)
fn premultiply(img: &mut RgbaImage) {
    for p in img.pixels_mut() {
        let a = p[3] as u32;
        for c in &mut p.0[..3] {
            *c = ((*c as u32 * a + 127) / 255) as u8;
        }
    }
}

/// Straight alpha from premultiplied texels (fully transparent ones become 0).
fn unpremultiply(data: &mut [u8]) {
    for p in data.as_chunks_mut::<4>().0 {
        let a = p[3] as u32;
        for c in &mut p[..3] {
            *c = (*c as u32 * 255 + a / 2).checked_div(a).map_or(0, |v| v.min(255) as u8);
        }
    }
}

/// Number of mip levels of a full chain down to 1x1.
pub(crate) fn mip_levels(w: u32, h: u32) -> u32 {
    32 - w.max(h).max(1).leading_zeros()
}

/// Decodes the texture `def` with the decoder limits of [`check_package`].
pub(crate) fn load(pkg: &Package, def: &TextureDef) -> Result<Texels, Error> {
    let (w, h, layers) = texture_size(pkg, def)?;
    let mut images: Vec<RgbaImage> = Vec::with_capacity(layers as usize);
    for f in def.files() {
        let img = reader(pkg.file(f)?)
            .map_err(|e| Error::Package(format!("texture `{f}`: {e}")))?
            .decode()
            .map_err(|e| Error::Package(format!("texture `{f}`: {e}")))?
            .to_rgba8();
        match def.grid {
            Some([cols, _]) => {
                for k in 0..layers {
                    let (x, y) = (k % cols * w, k / cols * h);
                    images.push(image::imageops::crop_imm(&img, x, y, w, h).to_image());
                }
            }
            None => images.push(img),
        }
    }
    if def.premultiply {
        images.iter_mut().for_each(premultiply);
    }
    let count = if def.mipmaps { mip_levels(w, h) } else { 1 };
    let mut levels = Vec::with_capacity(count as usize);
    levels.push(images.iter().flat_map(|i| i.as_raw().iter().copied()).collect());
    if count > 1 {
        // Levels are filtered premultiplied, so transparent texels do not darken the edges;
        // straight textures are divided back after.
        if !def.premultiply {
            images.iter_mut().for_each(premultiply);
        }
        for level in 1..count {
            let (lw, lh) = ((w >> level).max(1), (h >> level).max(1));
            // From the level above: a box-like halving.
            images = images.iter().map(|i| image::imageops::resize(i, lw, lh, image::imageops::FilterType::Triangle)).collect();
            let mut data: Vec<u8> = images.iter().flat_map(|i| i.as_raw().iter().copied()).collect();
            if !def.premultiply {
                unpremultiply(&mut data);
            }
            levels.push(data);
        }
    }
    Ok(Texels { width: w, height: h, layers, array: def.is_array(), levels })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mip_chain_reaches_one_texel() {
        assert_eq!(mip_levels(1, 1), 1);
        assert_eq!(mip_levels(2, 1), 2);
        assert_eq!(mip_levels(256, 128), 9);
        assert_eq!(mip_levels(255, 3), 8);
    }

    #[test]
    fn unpremultiply_undoes_premultiply() {
        let mut d = vec![128, 64, 5, 128, 9, 9, 9, 0, 255, 255, 255, 255];
        unpremultiply(&mut d);
        assert_eq!(d, [255, 128, 10, 128, 0, 0, 0, 0, 255, 255, 255, 255]);
    }

    #[test]
    fn premultiply_rounds_and_clears_transparent_colour() {
        let mut img = RgbaImage::from_raw(2, 1, vec![255, 0, 0, 0, 255, 128, 10, 128]).unwrap();
        premultiply(&mut img);
        assert_eq!(img.as_raw(), &[0, 0, 0, 0, 128, 64, 5, 128]);
    }
}
