//! `manifest.json` schema of an effect package.

use serde::Deserialize;

use crate::Error;

/// Highest manifest `api` version this runtime understands.
pub const MANIFEST_API: u32 = 1;

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
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TextureDef {
    pub name: String,
    /// Path of a PNG inside the package.
    pub path: String,
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
fn default_output_formats() -> Vec<String> {
    crate::PixelFormat::ALL.iter().map(|f| f.name().to_string()).collect()
}
fn default_inputs() -> Vec<InputDef> {
    vec![InputDef { name: "src".into(), description: String::new(), formats: Vec::new(), width: None, height: None, same_size: false }]
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
        }
        let mut param_names: Vec<&str> = Vec::new();
        for p in &self.params {
            declare(&p.name, "param", &mut param_names)?;
            param_names.push(&p.name);
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
}
