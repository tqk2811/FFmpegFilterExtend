//! `manifest.json` schema of an effect package.

use serde::Deserialize;

use crate::Error;

/// Highest manifest `api` version this runtime understands.
pub const MANIFEST_API: u32 = 2;

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    /// Manifest schema version. Bumped on breaking changes.
    #[serde(default = "default_api")]
    pub api: u32,
    /// Reverse-DNS identifier, e.g. `com.example.vignette`.
    pub id: String,
    /// Human readable name.
    pub name: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub description: String,
    /// Video inputs of the effect, in pad order. Defaults to a single `src` input.
    #[serde(default = "default_inputs")]
    pub inputs: Vec<InputDef>,
    /// Rules for the effect output.
    #[serde(default)]
    pub output: OutputDef,
    /// User tunable parameters, exposed to shaders as the `params` uniform struct.
    #[serde(default)]
    pub params: Vec<ParamDef>,
    /// Static images shipped in the package (LUTs, masks, overlays).
    #[serde(default)]
    pub textures: Vec<TextureDef>,
    /// Compute passes, executed in order. The output of the last pass is the effect output.
    pub passes: Vec<PassDef>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InputDef {
    pub name: String,
    #[serde(default)]
    pub description: String,
    /// Pixel formats (FFmpeg names, e.g. `yuv420p`, `rgba`) this input accepts.
    /// Empty accepts anything. Other formats are an error, never converted silently.
    #[serde(default)]
    pub formats: Vec<String>,
    #[serde(default)]
    pub width: Option<SizeRule>,
    #[serde(default)]
    pub height: Option<SizeRule>,
    /// The frame size must equal the size of the first input.
    #[serde(default)]
    pub same_size: bool,
    /// Give the texture of this input a full mip chain, made on the GPU every frame
    /// (api 2), for shaders that shrink it a lot with `textureSampleLevel`.
    #[serde(default)]
    pub mipmaps: bool,
}

/// Limits on one frame dimension, in pixels.
#[derive(Debug, Clone, Copy, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SizeRule {
    #[serde(default)]
    pub min: Option<u32>,
    #[serde(default)]
    pub max: Option<u32>,
    #[serde(default)]
    pub multiple_of: Option<u32>,
}

impl SizeRule {
    fn check(&self, what: &str, v: u32) -> Result<(), String> {
        if let Some(min) = self.min.filter(|&m| v < m) {
            return Err(format!("{what} {v} is below the minimum {min}"));
        }
        if let Some(max) = self.max.filter(|&m| v > m) {
            return Err(format!("{what} {v} is above the maximum {max}"));
        }
        if let Some(m) = self.multiple_of.filter(|&m| !v.is_multiple_of(m)) {
            return Err(format!("{what} {v} is not a multiple of {m}"));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OutputDef {
    /// Pixel formats the effect may produce, in order of preference. Defaults to `rgba`
    /// and every other format the runtime writes on the GPU ([`crate::PixelFormat`]).
    #[serde(default = "default_output_formats")]
    pub formats: Vec<String>,
}

impl Default for OutputDef {
    fn default() -> Self {
        OutputDef { formats: default_output_formats() }
    }
}

/// Properties of one input stream, checked against the manifest rules.
#[derive(Debug, Clone, Copy)]
pub struct StreamInfo<'a> {
    /// Pixel format name, or `None` when the caller does not know it (RGBA buffers).
    pub format: Option<&'a str>,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ParamType {
    Float,
    Int,
    Bool,
    Vec2,
    Vec3,
    Vec4,
    /// RGBA color, `vec4f` in shaders. Accepts `#rrggbb[aa]` or `r,g,b[,a]`.
    Color,
    /// A math expression over `vars`, compiled into the shaders as the function
    /// `gpufx_expr_<name>` (api 2). Not in the `params` struct.
    Expr,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ParamDef {
    pub name: String,
    #[serde(rename = "type")]
    pub kind: ParamType,
    #[serde(default)]
    pub default: Option<serde_json::Value>,
    #[serde(default)]
    pub min: Option<f64>,
    #[serde(default)]
    pub max: Option<f64>,
    #[serde(default)]
    pub description: String,
    /// Variables of an `expr` parameter: the arguments of its shader function, in order.
    #[serde(default)]
    pub vars: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TextureDef {
    pub name: String,
    /// Path of a PNG inside the package: a `texture_2d`, or with `grid` an atlas cut
    /// into the layers of a `texture_2d_array`.
    #[serde(default)]
    pub path: Option<String>,
    /// PNGs of the same size, the layers of a `texture_2d_array` (api 2).
    #[serde(default)]
    pub layers: Option<Vec<String>>,
    /// `[cols, rows]`: cuts the `path` atlas into layers, row by row (api 2).
    #[serde(default)]
    pub grid: Option<[u32; 2]>,
    /// Cells of the grid to use, when the last ones are empty. Defaults to `cols * rows`.
    #[serde(default)]
    pub count: Option<u32>,
    /// Make the full mip chain on the CPU when loading (api 2).
    #[serde(default)]
    pub mipmaps: bool,
    /// Multiply RGB by alpha when loading: shaders read premultiplied colours (api 2).
    #[serde(default)]
    pub premultiply: bool,
}

/// Most layers of a texture array (the default `max_texture_array_layers`).
pub const MAX_TEXTURE_LAYERS: u32 = 256;
/// Longest side of a package image, below the 8192 every device has.
pub const MAX_TEXTURE_SIDE: u32 = 4096;

impl TextureDef {
    /// The texture is a `texture_2d_array`.
    pub fn is_array(&self) -> bool {
        self.layers.is_some() || self.grid.is_some()
    }

    /// The PNG files the texture is made of.
    pub fn files(&self) -> Vec<&str> {
        match (&self.path, &self.layers) {
            (Some(p), _) => vec![p.as_str()],
            (None, Some(l)) => l.iter().map(String::as_str).collect(),
            (None, None) => Vec::new(),
        }
    }

    /// Number of layers, `None` for a plain `texture_2d`.
    pub fn layer_count(&self) -> Option<u32> {
        match (&self.layers, self.grid) {
            (Some(l), _) => Some(l.len() as u32),
            (None, Some([c, r])) => Some(self.count.unwrap_or(c * r)),
            (None, None) => None,
        }
    }

    fn uses_api2(&self) -> bool {
        self.is_array() || self.count.is_some() || self.mipmaps || self.premultiply
    }

    fn validate(&self) -> Result<(), String> {
        let n = &self.name;
        match (&self.path, &self.layers) {
            (Some(_), Some(_)) => return Err(format!("texture `{n}`: give `path` or `layers`, not both")),
            (None, None) => return Err(format!("texture `{n}`: needs `path` or `layers`")),
            (None, Some(l)) if l.is_empty() => return Err(format!("texture `{n}`: `layers` is empty")),
            _ => {}
        }
        if self.grid.is_some() && self.path.is_none() {
            return Err(format!("texture `{n}`: `grid` cuts a `path` atlas, it does not go with `layers`"));
        }
        if self.count.is_some() && self.grid.is_none() {
            return Err(format!("texture `{n}`: `count` only goes with `grid`"));
        }
        if let Some([c, r]) = self.grid {
            if c == 0 || r == 0 {
                return Err(format!("texture `{n}`: grid {c}x{r} has no cells"));
            }
            let cells = c as u64 * r as u64;
            match self.count {
                Some(0) => return Err(format!("texture `{n}`: count must be at least 1")),
                Some(k) if k as u64 > cells => return Err(format!("texture `{n}`: count {k} is more than the {cells} cells of the grid")),
                _ => {}
            }
            if self.count.map_or(cells, |k| k as u64) > MAX_TEXTURE_LAYERS as u64 {
                return Err(format!("texture `{n}`: more than {MAX_TEXTURE_LAYERS} layers"));
            }
        }
        if self.layers.as_ref().is_some_and(|l| l.len() > MAX_TEXTURE_LAYERS as usize) {
            return Err(format!("texture `{n}`: more than {MAX_TEXTURE_LAYERS} layers"));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PassDef {
    /// Path of the WGSL file inside the package.
    pub shader: String,
    /// Shader language. Inferred from the file extension when omitted:
    /// `.glsl`/`.comp` are GLSL, everything else WGSL.
    #[serde(default)]
    pub language: Option<ShaderLanguage>,
    /// Compute entry point (WGSL only; GLSL always uses `main`).
    #[serde(default = "default_entry")]
    pub entry: String,
    /// Textures this pass samples: effect inputs, package textures or earlier pass outputs.
    /// Defaults to all effect inputs followed by all package textures.
    #[serde(default)]
    pub inputs: Option<Vec<String>>,
    /// Name of the texture this pass writes. Defaults to `out`.
    #[serde(default = "default_output")]
    pub output: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ShaderLanguage {
    Wgsl,
    /// Vulkan-flavoured GLSL 450 compute shaders.
    Glsl,
}

impl PassDef {
    pub fn language(&self) -> ShaderLanguage {
        self.language.unwrap_or_else(|| {
            let lower = self.shader.to_ascii_lowercase();
            if lower.ends_with(".glsl") || lower.ends_with(".comp") {
                ShaderLanguage::Glsl
            } else {
                ShaderLanguage::Wgsl
            }
        })
    }
}

fn default_api() -> u32 {
    1
}
fn default_entry() -> String {
    "main".into()
}
fn default_output() -> String {
    "out".into()
}
pub(crate) fn default_output_formats() -> Vec<String> {
    crate::PixelFormat::ALL.iter().map(|f| f.name().to_string()).collect()
}
fn default_inputs() -> Vec<InputDef> {
    vec![InputDef {
        name: "src".into(),
        description: String::new(),
        formats: Vec::new(),
        width: None,
        height: None,
        same_size: false,
        mipmaps: false,
    }]
}

fn is_format_name(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

fn check_formats(list: &[String], what: &str) -> Result<(), Error> {
    for (i, f) in list.iter().enumerate() {
        if !is_format_name(f) {
            return Err(Error::Manifest(format!("{what}: `{f}` is not a pixel format name (e.g. `yuv420p`)")));
        }
        if list[..i].contains(f) {
            return Err(Error::Manifest(format!("{what}: duplicate format `{f}`")));
        }
    }
    Ok(())
}

fn check_size_rule(rule: &Option<SizeRule>, what: &str) -> Result<(), Error> {
    let Some(r) = rule else { return Ok(()) };
    if r.multiple_of == Some(0) {
        return Err(Error::Manifest(format!("{what}: multiple_of must be at least 1")));
    }
    if let (Some(a), Some(b)) = (r.min, r.max) {
        if a > b {
            return Err(Error::Manifest(format!("{what}: min {a} is greater than max {b}")));
        }
    }
    Ok(())
}

pub(crate) fn is_ident(s: &str) -> bool {
    let mut chars = s.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
        && !s.starts_with("gpufx")
        && !RESERVED.contains(&s)
}

/// Names the generated prelude already declares.
const RESERVED: &[&str] = &["globals", "params", "out_tex", "smp"];

impl Manifest {
    pub fn parse(bytes: &[u8]) -> Result<Self, Error> {
        // The api first: a newer package should say so, not fail on its new fields.
        #[derive(Deserialize)]
        struct Api {
            #[serde(default = "default_api")]
            api: u32,
        }
        if let Ok(Api { api }) = serde_json::from_slice::<Api>(bytes) {
            if api > MANIFEST_API {
                return Err(Error::Manifest(format!("unsupported manifest api {api} (runtime supports <= {MANIFEST_API})")));
            }
        }
        let m: Manifest = serde_json::from_slice(bytes).map_err(|e| Error::Manifest(e.to_string()))?;
        m.validate()?;
        Ok(m)
    }

    fn validate(&self) -> Result<(), Error> {
        let bad = |msg: String| Err(Error::Manifest(msg));
        if self.api == 0 || self.api > MANIFEST_API {
            return bad(format!("unsupported manifest api {} (runtime supports <= {MANIFEST_API})", self.api));
        }
        if self.inputs.is_empty() {
            return bad("an effect needs at least one input".into());
        }
        if self.passes.is_empty() {
            return bad("an effect needs at least one pass".into());
        }
        let mut names: Vec<&str> = Vec::new();
        let declare = |n: &str, what: &str, names: &mut Vec<&str>| -> Result<(), Error> {
            if !is_ident(n) {
                return Err(Error::Manifest(format!("{what} name `{n}` is not a valid identifier (or is reserved)")));
            }
            if names.contains(&n) {
                return Err(Error::Manifest(format!("duplicate name `{n}`")));
            }
            Ok(())
        };
        for (idx, i) in self.inputs.iter().enumerate() {
            declare(&i.name, "input", &mut names)?;
            names.push(&i.name);
            check_formats(&i.formats, &format!("input `{}` formats", i.name))?;
            check_size_rule(&i.width, &format!("input `{}` width", i.name))?;
            check_size_rule(&i.height, &format!("input `{}` height", i.name))?;
            if idx == 0 && i.same_size {
                return bad(format!("input `{}` is the first input; same_size only applies to later inputs", i.name));
            }
        }
        if self.output.formats.is_empty() {
            return bad("output formats must list at least one pixel format".into());
        }
        check_formats(&self.output.formats, "output formats")?;
        for t in &self.textures {
            declare(&t.name, "texture", &mut names)?;
            names.push(&t.name);
            t.validate().map_err(Error::Manifest)?;
            if t.uses_api2() && self.api < 2 {
                return bad(format!("texture `{}`: layers, grid, count, mipmaps and premultiply need \"api\": 2", t.name));
            }
        }
        for i in &self.inputs {
            if i.mipmaps && self.api < 2 {
                return bad(format!("input `{}`: mipmaps needs \"api\": 2", i.name));
            }
        }
        let mut param_names: Vec<&str> = Vec::new();
        for p in &self.params {
            declare(&p.name, "param", &mut param_names)?;
            if p.name == "enable" || p.name == "bypass" {
                // `<node>.enable` and `<node>.bypass` switch an effect of a chain or graph (the filter's `params`).
                return bad(format!("param name `{}` is reserved: `<effect>.enable` and `<effect>.bypass` switch an effect of a chain or graph", p.name));
            }
            param_names.push(&p.name);
            if p.kind == ParamType::Expr {
                if self.api < 2 {
                    return bad(format!("param `{}`: type expr needs \"api\": 2", p.name));
                }
                if !p.default.as_ref().is_some_and(serde_json::Value::is_string) {
                    return bad(format!("param `{}`: an expr needs a default expression (a string)", p.name));
                }
                if p.min.is_some() || p.max.is_some() {
                    return bad(format!("param `{}`: an expr has no min or max", p.name));
                }
                for (k, v) in p.vars.iter().enumerate() {
                    let plain = !v.is_empty()
                        && v.len() <= 32
                        && v.starts_with(|c: char| c.is_ascii_alphabetic())
                        && !v.contains("__")
                        && v.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
                    if !plain {
                        return bad(format!("param `{}`: variable `{v}` is not an identifier", p.name));
                    }
                    if p.vars[..k].contains(v) {
                        return bad(format!("param `{}`: duplicate variable `{v}`", p.name));
                    }
                }
            } else if !p.vars.is_empty() {
                return bad(format!("param `{}`: only an expr has vars", p.name));
            }
        }
        for (i, pass) in self.passes.iter().enumerate() {
            for src in pass.inputs.iter().flatten() {
                if !names.contains(&src.as_str()) {
                    return bad(format!("pass {i} reads `{src}`, which is not an input, texture or earlier pass output"));
                }
            }
            if !is_ident(&pass.output) {
                return bad(format!("pass {i} output `{}` is not a valid identifier", pass.output));
            }
            if pass.inputs.iter().flatten().any(|s| *s == pass.output) {
                return bad(format!("pass {i} cannot read its own output `{}`", pass.output));
            }
            if self.inputs.iter().any(|x| x.name == pass.output) || self.textures.iter().any(|x| x.name == pass.output) {
                return bad(format!("pass {i} output `{}` shadows an input or texture", pass.output));
            }
            if !names.contains(&pass.output.as_str()) {
                names.push(&pass.output);
            }
        }
        Ok(())
    }

    /// Checks input streams against the `inputs` rules (count, pixel format, size).
    /// The error names the input and the rule that failed.
    pub fn check_inputs(&self, streams: &[StreamInfo]) -> Result<(), Error> {
        if streams.len() != self.inputs.len() {
            return Err(Error::Unsupported(format!("effect `{}` takes {} input(s), got {}", self.name, self.inputs.len(), streams.len())));
        }
        let first = (streams[0].width, streams[0].height);
        for (def, s) in self.inputs.iter().zip(streams) {
            let fail = |msg: String| Error::Unsupported(format!("input `{}` of `{}`: {msg}", def.name, self.name));
            if let Some(f) = s.format {
                if !def.formats.is_empty() && !def.formats.iter().any(|x| x == f) {
                    return Err(fail(format!("pixel format `{f}` is not supported (accepted: {})", def.formats.join(", "))));
                }
            }
            if let Some(r) = &def.width {
                r.check("width", s.width).map_err(fail)?;
            }
            if let Some(r) = &def.height {
                r.check("height", s.height).map_err(fail)?;
            }
            if def.same_size && (s.width, s.height) != first {
                return Err(fail(format!("size {}x{} must equal the first input ({}x{})", s.width, s.height, first.0, first.1)));
            }
        }
        Ok(())
    }

    /// Checks that the effect may produce `format`.
    pub fn check_output_format(&self, format: &str) -> Result<(), Error> {
        if self.output.formats.iter().any(|x| x == format) {
            Ok(())
        } else {
            Err(Error::Unsupported(format!(
                "output of `{}`: pixel format `{format}` is not supported (supported: {})",
                self.name,
                self.output.formats.join(", ")
            )))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(inputs: &str, output: &str) -> Result<Manifest, Error> {
        Manifest::parse(format!(r#"{{"id":"t.x","name":"X","inputs":{inputs}{output},"passes":[{{"shader":"a.wgsl"}}]}}"#).as_bytes())
    }

    fn info(format: &str, width: u32, height: u32) -> StreamInfo<'_> {
        StreamInfo { format: Some(format), width, height }
    }

    #[test]
    fn default_rules_accept_anything_and_output_gpu_formats() {
        let m = manifest(r#"[{"name":"src"}]"#, "").unwrap();
        m.check_inputs(&[info("yuv420p", 3, 5)]).unwrap();
        assert_eq!(m.output.formats[0], "rgba");
        m.check_output_format("yuv420p").unwrap();
        m.check_output_format("p010le").unwrap();
        assert!(m.check_output_format("gray").is_err());
    }

    #[test]
    fn input_rules_reject_mismatches() {
        let m = manifest(
            r#"[{"name":"a","formats":["yuv420p","rgba"],"width":{"min":16,"max":64,"multiple_of":2}},
                {"name":"b","same_size":true}]"#,
            r#","output":{"formats":["yuv420p"]}"#,
        )
        .unwrap();
        m.check_inputs(&[info("rgba", 32, 9), info("gray", 32, 9)]).unwrap();
        let err = |s: &[StreamInfo]| m.check_inputs(s).unwrap_err().to_string();
        assert!(err(&[info("nv12", 32, 9), info("rgba", 32, 9)]).contains("pixel format `nv12` is not supported"));
        assert!(err(&[info("rgba", 8, 9), info("rgba", 8, 9)]).contains("below the minimum 16"));
        assert!(err(&[info("rgba", 66, 9), info("rgba", 66, 9)]).contains("above the maximum 64"));
        assert!(err(&[info("rgba", 33, 9), info("rgba", 33, 9)]).contains("not a multiple of 2"));
        assert!(err(&[info("rgba", 32, 9), info("rgba", 32, 8)]).contains("must equal the first input"));
        assert!(err(&[info("rgba", 32, 9)]).contains("takes 2 input(s), got 1"));
        // Unknown format (RGBA buffers from the CLI) only checks sizes.
        m.check_inputs(&[StreamInfo { format: None, ..info("", 32, 9) }; 2]).unwrap();
        m.check_output_format("yuv420p").unwrap();
        assert!(m.check_output_format("rgba").is_err());
    }

    #[test]
    fn invalid_rules_are_manifest_errors() {
        assert!(manifest(r#"[{"name":"a","formats":["YUV 420"]}]"#, "").is_err());
        assert!(manifest(r#"[{"name":"a","formats":["rgba","rgba"]}]"#, "").is_err());
        assert!(manifest(r#"[{"name":"a","width":{"min":10,"max":5}}]"#, "").is_err());
        assert!(manifest(r#"[{"name":"a","height":{"multiple_of":0}}]"#, "").is_err());
        assert!(manifest(r#"[{"name":"a","same_size":true}]"#, "").is_err());
        assert!(manifest(r#"[{"name":"a"}]"#, r#","output":{"formats":[]}"#).is_err());
    }

    fn textures(api: u32, list: &str) -> Result<Manifest, Error> {
        Manifest::parse(format!(r#"{{"api":{api},"id":"t.x","name":"X","textures":[{list}],"passes":[{{"shader":"a.wgsl"}}]}}"#).as_bytes())
    }

    #[test]
    fn texture_arrays_follow_their_rules() {
        let m = textures(2, r#"{"name":"a","layers":["x.png","y.png"],"mipmaps":true},{"name":"b","path":"g.png","grid":[4,2],"count":7,"premultiply":true},{"name":"c","path":"p.png"}"#).unwrap();
        assert_eq!(m.textures[0].layer_count(), Some(2));
        assert_eq!(m.textures[1].layer_count(), Some(7));
        assert_eq!(m.textures[2].layer_count(), None);
        assert!(m.textures[0].is_array() && m.textures[1].is_array() && !m.textures[2].is_array());
        let err = |api: u32, t: &str| textures(api, t).unwrap_err().to_string();
        assert!(err(2, r#"{"name":"a","path":"x.png","layers":["y.png"]}"#).contains("not both"));
        assert!(err(2, r#"{"name":"a"}"#).contains("needs `path` or `layers`"));
        assert!(err(2, r#"{"name":"a","layers":[]}"#).contains("empty"));
        assert!(err(2, r#"{"name":"a","layers":["x.png"],"grid":[1,1]}"#).contains("does not go with `layers`"));
        assert!(err(2, r#"{"name":"a","path":"x.png","count":2}"#).contains("only goes with `grid`"));
        assert!(err(2, r#"{"name":"a","path":"x.png","grid":[2,2],"count":5}"#).contains("more than the 4 cells"));
        assert!(err(2, r#"{"name":"a","path":"x.png","grid":[0,2]}"#).contains("no cells"));
        assert!(err(2, r#"{"name":"a","path":"x.png","grid":[32,9]}"#).contains("more than 256 layers"));
        textures(2, r#"{"name":"a","path":"x.png","grid":[32,9],"count":256}"#).unwrap();
        let many = vec![r#""x.png""#; 257].join(",");
        assert!(err(2, &format!(r#"{{"name":"a","layers":[{many}]}}"#)).contains("more than 256 layers"));
        for field in [
            r#""layers":["x.png"]"#,
            r#""path":"x.png","grid":[1,1]"#,
            r#""path":"x.png","mipmaps":true"#,
            r#""path":"x.png","premultiply":true"#,
        ] {
            assert!(err(1, &format!(r#"{{"name":"a",{field}}}"#)).contains(r#""api": 2"#), "{field}");
        }
        assert!(manifest(r#"[{"name":"a","mipmaps":true}]"#, "").unwrap_err().to_string().contains(r#""api": 2"#));
        let var = |v: &str| {
            Manifest::parse(format!(r#"{{"api":2,"id":"t.x","name":"X","params":[{{"name":"e","type":"expr","default":"1","vars":["{v}"]}}],"passes":[{{"shader":"a.wgsl"}}]}}"#).as_bytes())
        };
        var("u_2").unwrap();
        assert!(var("_u").is_err() && var("a__b").is_err() && var("2u").is_err());
        // `enable` switches an effect of a chain or graph (`0.enable`): no package declares it.
        let param = |n: &str| {
            Manifest::parse(
                format!(
                    r#"{{"id":"t.x","name":"X","params":[{{"name":"{n}","type":"float","default":1}}],"passes":[{{"shader":"a.wgsl"}}]}}"#
                )
                .as_bytes(),
            )
        };
        param("enabled").unwrap();
        assert!(param("enable").unwrap_err().to_string().contains("`enable` is reserved"));
        assert!(param("bypass").unwrap_err().to_string().contains("`bypass` is reserved"));
        assert!(err(3, r#"{"name":"a","path":"x.png","colorspace":"linear"}"#).contains("unsupported manifest api 3"));
    }
}
