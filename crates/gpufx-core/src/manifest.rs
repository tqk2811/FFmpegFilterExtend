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
fn default_inputs() -> Vec<InputDef> {
    vec![InputDef { name: "src".into(), description: String::new() }]
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
        for i in &self.inputs {
            declare(&i.name, "input", &mut names)?;
            names.push(&i.name);
        }
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
}
