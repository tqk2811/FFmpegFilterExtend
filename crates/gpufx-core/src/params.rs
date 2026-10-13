//! Parameter values and their uniform-buffer layout (WGSL uniform address space rules).

use crate::expr::Expr;
use crate::manifest::{ParamDef, ParamType};
use crate::Error;

impl ParamType {
    /// `(align, size)` in bytes in the uniform address space.
    fn layout(self) -> (usize, usize) {
        match self {
            ParamType::Float | ParamType::Int | ParamType::Bool => (4, 4),
            ParamType::Expr => (1, 0),
            ParamType::Vec2 => (8, 8),
            ParamType::Vec3 => (16, 12),
            ParamType::Vec4 | ParamType::Color => (16, 16),
        }
    }

    pub(crate) fn wgsl(self) -> &'static str {
        match self {
            ParamType::Float | ParamType::Expr => "f32",
            ParamType::Int => "i32",
            ParamType::Bool => "u32",
            ParamType::Vec2 => "vec2f",
            ParamType::Vec3 => "vec3f",
            ParamType::Vec4 | ParamType::Color => "vec4f",
        }
    }

    pub(crate) fn glsl(self) -> &'static str {
        match self {
            ParamType::Float | ParamType::Expr => "float",
            ParamType::Int => "int",
            ParamType::Bool => "uint",
            ParamType::Vec2 => "vec2",
            ParamType::Vec3 => "vec3",
            ParamType::Vec4 | ParamType::Color => "vec4",
        }
    }

    fn components(self) -> usize {
        match self {
            ParamType::Expr => 0,
            ParamType::Float | ParamType::Int | ParamType::Bool => 1,
            ParamType::Vec2 => 2,
            ParamType::Vec3 => 3,
            ParamType::Vec4 | ParamType::Color => 4,
        }
    }
}

/// A parameter's value, stored as up to four f32 (ints and bools are stored exactly).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Value(pub [f64; 4]);

/// Uniform block holding all parameter values, laid out as the generated `GpufxParams` struct.
#[derive(Debug, Clone)]
pub struct ParamBlock {
    defs: Vec<ParamDef>,
    offsets: Vec<usize>,
    values: Vec<Value>,
    /// The parsed expression of each `expr` parameter.
    exprs: Vec<Option<Expr>>,
    size: usize,
}

impl ParamBlock {
    pub fn new(defs: &[ParamDef]) -> Result<Self, Error> {
        let mut offsets = Vec::with_capacity(defs.len());
        let mut off = 0usize;
        for d in defs {
            let (align, size) = d.kind.layout();
            off = off.next_multiple_of(align);
            offsets.push(off);
            off += size;
        }
        // Struct size is rounded to its alignment (16 is safe); never zero-sized.
        let size = off.max(4).next_multiple_of(16);
        let mut block = ParamBlock { defs: defs.to_vec(), offsets, values: Vec::new(), exprs: Vec::new(), size };
        for d in defs {
            if d.kind == ParamType::Expr {
                let text = d.default.as_ref().and_then(|j| j.as_str()).unwrap_or("0");
                let e = Expr::parse(text, &d.vars).map_err(|e| Error::Param(format!("default of `{}`: {e}", d.name)))?;
                block.exprs.push(Some(e));
                block.values.push(Value([0.0; 4]));
                continue;
            }
            let v = match &d.default {
                None => Value([0.0; 4]),
                Some(json) => parse_json(d, json)?,
            };
            block.values.push(clamp(d, v));
            block.exprs.push(None);
        }
        Ok(block)
    }

    pub fn defs(&self) -> &[ParamDef] {
        &self.defs
    }

    pub fn size(&self) -> usize {
        self.size
    }

    pub fn get(&self, name: &str) -> Option<Value> {
        self.index(name).map(|i| self.values[i])
    }

    fn index(&self, name: &str) -> Option<usize> {
        self.defs.iter().position(|d| d.name == name)
    }

    /// Sets a parameter from its textual form (`0.5`, `1,0,0`, `#ff8800`, `true`).
    pub fn set_str(&mut self, name: &str, text: &str) -> Result<(), Error> {
        let i = self.index(name).ok_or_else(|| Error::Param(format!("unknown parameter `{name}`")))?;
        if self.defs[i].kind == ParamType::Expr {
            let e = Expr::parse(text, &self.defs[i].vars).map_err(|e| Error::Param(format!("`{name}`: {e}")))?;
            self.exprs[i] = Some(e);
            return Ok(());
        }
        let v = parse_str(&self.defs[i], text)?;
        self.values[i] = clamp(&self.defs[i], v);
        Ok(())
    }

    /// The expression of an `expr` parameter.
    pub fn expr(&self, name: &str) -> Option<&Expr> {
        self.index(name).and_then(|i| self.exprs[i].as_ref())
    }

    /// Sets every `expr` parameter back to `texts` (as [`ParamBlock::expr_key`] gave them).
    pub(crate) fn restore_exprs(&mut self, texts: &[String]) {
        let slots = self.defs.iter().zip(self.exprs.iter_mut()).filter(|(_, e)| e.is_some());
        for ((d, e), text) in slots.zip(texts) {
            if let Ok(parsed) = Expr::parse(text, &d.vars) {
                *e = Some(parsed);
            }
        }
    }

    /// The texts of every `expr` parameter: when it changes, the shaders must be rebuilt.
    pub(crate) fn expr_key(&self) -> Vec<&str> {
        self.exprs.iter().flatten().map(Expr::text).collect()
    }

    /// The shader functions of the `expr` parameters, in WGSL or GLSL.
    pub(crate) fn expr_functions(&self, glsl: bool) -> String {
        let mut s = String::new();
        if self.exprs.iter().any(Option::is_some) {
            s.push_str(Expr::helper(glsl));
        }
        for (d, e) in self.defs.iter().zip(&self.exprs) {
            if let Some(e) = e {
                s.push_str(&if glsl { e.glsl_fn(&d.name, &d.vars) } else { e.wgsl_fn(&d.name, &d.vars) });
            }
        }
        s
    }

    /// Sets a parameter from numbers; missing components are kept from the current value.
    pub fn set(&mut self, name: &str, comps: &[f64]) -> Result<(), Error> {
        let i = self.index(name).ok_or_else(|| Error::Param(format!("unknown parameter `{name}`")))?;
        if self.defs[i].kind == ParamType::Expr {
            return Err(Error::Param(format!("`{name}` is an expression parameter: it takes text such as `0.1*sin(u)`, not numbers")));
        }
        let mut v = self.values[i];
        for (dst, src) in v.0.iter_mut().zip(comps) {
            *dst = *src;
        }
        self.values[i] = clamp(&self.defs[i], v);
        Ok(())
    }

    /// WGSL declaration of the struct matching [`ParamBlock::bytes`].
    pub(crate) fn wgsl_struct(&self) -> String {
        let mut s = String::from("struct GpufxParams {\n");
        if self.uniforms().next().is_none() {
            s.push_str("    _unused: f32,\n");
        }
        for d in self.uniforms() {
            s.push_str(&format!("    {}: {},\n", d.name, d.kind.wgsl()));
        }
        s.push_str("};\n");
        s
    }

    /// GLSL std140 block members matching [`ParamBlock::bytes`] (same offsets as WGSL
    /// for the scalar and vector types used here).
    pub(crate) fn glsl_members(&self) -> String {
        let mut s = String::new();
        if self.uniforms().next().is_none() {
            s.push_str("    float _unused;\n");
        }
        for d in self.uniforms() {
            s.push_str(&format!("    {} {};\n", d.kind.glsl(), d.name));
        }
        s
    }

    /// The parameters held in the uniform block (all but `expr`).
    fn uniforms(&self) -> impl Iterator<Item = &ParamDef> {
        self.defs.iter().filter(|d| d.kind != ParamType::Expr)
    }

    pub fn bytes(&self) -> Vec<u8> {
        let mut out = vec![0u8; self.size];
        for ((d, off), v) in self.defs.iter().zip(&self.offsets).zip(&self.values) {
            for c in 0..d.kind.components() {
                let at = off + c * 4;
                let raw: [u8; 4] = match d.kind {
                    ParamType::Int => (v.0[c].round() as i32).to_le_bytes(),
                    ParamType::Bool => ((v.0[c] != 0.0) as u32).to_le_bytes(),
                    _ => (v.0[c] as f32).to_le_bytes(),
                };
                out[at..at + 4].copy_from_slice(&raw);
            }
        }
        out
    }
}

fn clamp(d: &ParamDef, mut v: Value) -> Value {
    for c in v.0.iter_mut().take(d.kind.components()) {
        if let Some(min) = d.min {
            *c = c.max(min);
        }
        if let Some(max) = d.max {
            *c = c.min(max);
        }
    }
    v
}

fn parse_json(d: &ParamDef, json: &serde_json::Value) -> Result<Value, Error> {
    use serde_json::Value as J;
    let bad = || Error::Param(format!("invalid default for `{}`", d.name));
    let mut v = [0.0; 4];
    match json {
        J::Number(n) => v[0] = n.as_f64().ok_or_else(bad)?,
        J::Bool(b) => v[0] = *b as u8 as f64,
        J::String(s) => return parse_str(d, s),
        J::Array(a) => {
            if a.len() > 4 {
                return Err(bad());
            }
            for (dst, src) in v.iter_mut().zip(a) {
                *dst = src.as_f64().ok_or_else(bad)?;
            }
            if d.kind == ParamType::Color && a.len() == 3 {
                v[3] = 1.0;
            }
        }
        _ => return Err(bad()),
    }
    Ok(Value(v))
}

fn parse_str(d: &ParamDef, text: &str) -> Result<Value, Error> {
    let text = text.trim();
    let bad = || Error::Param(format!("cannot parse `{text}` as {:?} for `{}`", d.kind, d.name));
    let mut v = [0.0; 4];
    match d.kind {
        ParamType::Bool => {
            v[0] = match text.to_ascii_lowercase().as_str() {
                "1" | "true" | "yes" | "on" => 1.0,
                "0" | "false" | "no" | "off" => 0.0,
                _ => return Err(bad()),
            }
        }
        ParamType::Color if text.starts_with('#') => {
            let hex = &text[1..];
            if !(hex.len() == 6 || hex.len() == 8) {
                return Err(bad());
            }
            v[3] = 1.0;
            for (i, chunk) in hex.as_bytes().chunks(2).enumerate() {
                let s = std::str::from_utf8(chunk).map_err(|_| bad())?;
                v[i] = u8::from_str_radix(s, 16).map_err(|_| bad())? as f64 / 255.0;
            }
        }
        _ => {
            let parts: Vec<&str> = text.split([',', ' ']).filter(|s| !s.is_empty()).collect();
            let n = d.kind.components();
            let ok_len = parts.len() == n || (d.kind == ParamType::Color && parts.len() == 3);
            if !ok_len {
                return Err(bad());
            }
            if d.kind == ParamType::Color {
                v[3] = 1.0;
            }
            for (dst, s) in v.iter_mut().zip(&parts) {
                *dst = s.parse::<f64>().map_err(|_| bad())?;
            }
        }
    }
    Ok(Value(v))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn def(name: &str, kind: ParamType) -> ParamDef {
        ParamDef { name: name.into(), kind, default: None, min: None, max: None, description: String::new(), vars: Vec::new() }
    }

    #[test]
    fn layout_follows_wgsl_uniform_rules() {
        let defs = [def("a", ParamType::Float), def("b", ParamType::Vec3), def("c", ParamType::Vec2), def("d", ParamType::Color)];
        let b = ParamBlock::new(&defs).unwrap();
        assert_eq!(b.offsets, vec![0, 16, 32, 48]);
        assert_eq!(b.size(), 64);
    }

    #[test]
    fn parses_colors_and_vectors() {
        let mut b = ParamBlock::new(&[def("c", ParamType::Color), def("v", ParamType::Vec2)]).unwrap();
        b.set_str("c", "#ff000080").unwrap();
        let c = b.get("c").unwrap().0;
        assert_eq!((c[0], c[1]), (1.0, 0.0));
        assert!((c[3] - 128.0 / 255.0).abs() < 1e-9);
        b.set_str("v", "0.25,0.75").unwrap();
        assert_eq!(b.get("v").unwrap().0[..2], [0.25, 0.75]);
        assert!(b.set_str("v", "1").is_err());
    }

    #[test]
    fn clamps_to_range() {
        let mut d = def("x", ParamType::Float);
        d.min = Some(0.0);
        d.max = Some(1.0);
        let mut b = ParamBlock::new(&[d]).unwrap();
        b.set_str("x", "5").unwrap();
        assert_eq!(b.get("x").unwrap().0[0], 1.0);
    }

    #[test]
    fn expressions_take_no_uniform_space() {
        let mut e = def("path", ParamType::Expr);
        e.default = Some(serde_json::json!("u * 2"));
        e.vars = vec!["u".into()];
        let defs = [def("a", ParamType::Float), e, def("b", ParamType::Vec2)];
        let mut b = ParamBlock::new(&defs).unwrap();
        assert_eq!(b.offsets, vec![0, 4, 8]);
        assert_eq!(b.size(), 16);
        assert!(!b.wgsl_struct().contains("path") && !b.glsl_members().contains("path"));
        assert_eq!(b.expr_key(), ["u * 2"]);
        b.set_str("path", "sin(u)").unwrap();
        assert_eq!(b.expr("path").unwrap().eval(&[0.0]), 0.0);
        assert!(b.set_str("path", "sin(v)").is_err());
        assert_eq!(b.expr_key(), ["sin(u)"], "a bad expression keeps the last good one");
        assert!(b.set("path", &[1.0]).unwrap_err().to_string().contains("expression parameter"));
        assert!(b.expr_functions(false).contains("\nfn gpufx_expr_path(gpufx_v_u: f32) -> f32"));
    }
}
