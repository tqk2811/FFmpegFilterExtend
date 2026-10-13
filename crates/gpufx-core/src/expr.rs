//! `expr` parameters: small math expressions given as text (from the command line or
//! `sendcmd`) and compiled into the shaders as functions, so they are evaluated per
//! pixel or per particle on the GPU. The text is parsed into a tree and the shader code
//! is generated from the tree, never pasted: only numbers, the declared variables,
//! `+ - * / ^`, parentheses and a fixed list of math functions get through.

use crate::Error;

/// Longest expression text, in bytes.
pub const MAX_EXPR_LEN: usize = 1024;
/// Most nodes (numbers, variables, operators, calls) of one expression.
const MAX_NODES: usize = 512;
/// Deepest nesting of one expression.
const MAX_DEPTH: usize = 32;

/// Functions an expression may call: name, arity, WGSL name, GLSL name.
const FUNCTIONS: &[(&str, usize, &str, &str)] = &[
    ("sin", 1, "sin", "sin"),
    ("cos", 1, "cos", "cos"),
    ("tan", 1, "tan", "tan"),
    ("asin", 1, "asin", "asin"),
    ("acos", 1, "acos", "acos"),
    ("atan", 1, "atan", "atan"),
    ("atan2", 2, "atan2", "atan"),
    ("abs", 1, "abs", "abs"),
    ("sign", 1, "sign", "sign"),
    ("min", 2, "min", "min"),
    ("max", 2, "max", "max"),
    ("clamp", 3, "clamp", "clamp"),
    ("mix", 3, "mix", "mix"),
    ("step", 2, "step", "step"),
    ("smoothstep", 3, "smoothstep", "smoothstep"),
    ("pow", 2, "pow", "pow"),
    ("sqrt", 1, "sqrt", "sqrt"),
    ("exp", 1, "exp", "exp"),
    ("log", 1, "log", "log"),
    ("floor", 1, "floor", "floor"),
    ("ceil", 1, "ceil", "ceil"),
    ("round", 1, "round", "round"),
    ("fract", 1, "fract", "fract"),
];

/// Named constants.
const CONSTANTS: &[(&str, f64)] = &[("pi", std::f64::consts::PI), ("tau", std::f64::consts::TAU), ("e", std::f64::consts::E)];

#[derive(Debug, Clone, PartialEq)]
enum Node {
    Num(f64),
    /// Index into the declared variables.
    Var(usize),
    Neg(Box<Node>),
    Bin(char, Box<Node>, Box<Node>),
    /// Index into [`FUNCTIONS`].
    Call(usize, Vec<Node>),
}

/// A parsed expression over the variables it was parsed with.
#[derive(Debug, Clone, PartialEq)]
pub struct Expr {
    text: String,
    root: Node,
}

struct Parser<'a> {
    s: &'a [u8],
    pos: usize,
    vars: &'a [String],
    nodes: usize,
}

impl Parser<'_> {
    fn err(&self, msg: impl std::fmt::Display) -> Error {
        Error::Param(format!("expression `{}`: {msg} at column {}", String::from_utf8_lossy(self.s), self.pos + 1))
    }

    fn skip(&mut self) {
        while self.s.get(self.pos).is_some_and(|c| c.is_ascii_whitespace()) {
            self.pos += 1;
        }
    }

    fn eat(&mut self, c: u8) -> bool {
        self.skip();
        if self.s.get(self.pos) == Some(&c) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn node(&mut self, n: Node) -> Result<Node, Error> {
        self.nodes += 1;
        if self.nodes > MAX_NODES {
            return Err(self.err(format!("more than {MAX_NODES} terms")));
        }
        Ok(n)
    }

    fn sum(&mut self, depth: usize) -> Result<Node, Error> {
        if depth > MAX_DEPTH {
            return Err(self.err(format!("nested deeper than {MAX_DEPTH}")));
        }
        let mut left = self.product(depth)?;
        loop {
            let op = if self.eat(b'+') {
                '+'
            } else if self.eat(b'-') {
                '-'
            } else {
                return Ok(left);
            };
            let right = self.product(depth)?;
            left = self.node(Node::Bin(op, Box::new(left), Box::new(right)))?;
        }
    }

    fn product(&mut self, depth: usize) -> Result<Node, Error> {
        let mut left = self.unary(depth)?;
        loop {
            let op = if self.eat(b'*') {
                '*'
            } else if self.eat(b'/') {
                '/'
            } else {
                return Ok(left);
            };
            let right = self.unary(depth)?;
            left = self.node(Node::Bin(op, Box::new(left), Box::new(right)))?;
        }
    }

    fn unary(&mut self, depth: usize) -> Result<Node, Error> {
        if depth > MAX_DEPTH {
            return Err(self.err(format!("nested deeper than {MAX_DEPTH}")));
        }
        if self.eat(b'-') {
            let inner = self.unary(depth + 1)?;
            return self.node(Node::Neg(Box::new(inner)));
        }
        if self.eat(b'+') {
            return self.unary(depth + 1);
        }
        let base = self.atom(depth)?;
        if self.eat(b'^') {
            // Right associative: 2^3^2 = 2^(3^2); -x^2 = -(x^2).
            let exp = self.unary(depth + 1)?;
            return self.node(Node::Call(FUNCTIONS.iter().position(|f| f.0 == "pow").expect("listed"), vec![base, exp]));
        }
        Ok(base)
    }

    fn atom(&mut self, depth: usize) -> Result<Node, Error> {
        self.skip();
        let start = self.pos;
        let Some(&c) = self.s.get(self.pos) else { return Err(self.err("unexpected end")) };
        if c == b'(' {
            self.pos += 1;
            let inner = self.sum(depth + 1)?;
            if !self.eat(b')') {
                return Err(self.err("expected `)`"));
            }
            return Ok(inner);
        }
        if c.is_ascii_digit() || c == b'.' {
            while self.s.get(self.pos).is_some_and(|c| c.is_ascii_digit() || *c == b'.') {
                self.pos += 1;
            }
            if self.s.get(self.pos).is_some_and(|c| *c == b'e' || *c == b'E') {
                let save = self.pos;
                self.pos += 1;
                if self.s.get(self.pos).is_some_and(|c| *c == b'+' || *c == b'-') {
                    self.pos += 1;
                }
                if self.s.get(self.pos).is_some_and(u8::is_ascii_digit) {
                    while self.s.get(self.pos).is_some_and(u8::is_ascii_digit) {
                        self.pos += 1;
                    }
                } else {
                    self.pos = save;
                }
            }
            let text = std::str::from_utf8(&self.s[start..self.pos]).expect("ascii");
            let v: f64 = text.parse().map_err(|_| self.err(format!("bad number `{text}`")))?;
            if !v.is_finite() || v.abs() > f32::MAX as f64 {
                return Err(self.err(format!("number `{text}` is out of range")));
            }
            return self.node(Node::Num(v));
        }
        if c.is_ascii_alphabetic() || c == b'_' {
            while self.s.get(self.pos).is_some_and(|c| c.is_ascii_alphanumeric() || *c == b'_') {
                self.pos += 1;
            }
            let name = std::str::from_utf8(&self.s[start..self.pos]).expect("ascii");
            if self.eat(b'(') {
                let Some(f) = FUNCTIONS.iter().position(|f| f.0 == name) else {
                    self.pos = start;
                    let list: Vec<&str> = FUNCTIONS.iter().map(|f| f.0).collect();
                    return Err(self.err(format!("unknown function `{name}` (known: {})", list.join(" "))));
                };
                let mut args = Vec::new();
                if !self.eat(b')') {
                    loop {
                        args.push(self.sum(depth + 1)?);
                        if self.eat(b')') {
                            break;
                        }
                        if !self.eat(b',') {
                            return Err(self.err("expected `,` or `)`"));
                        }
                    }
                }
                if args.len() != FUNCTIONS[f].1 {
                    return Err(self.err(format!("{name} takes {} argument(s), got {}", FUNCTIONS[f].1, args.len())));
                }
                return self.node(Node::Call(f, args));
            }
            if let Some(v) = self.vars.iter().position(|v| v == name) {
                return self.node(Node::Var(v));
            }
            if let Some(&(_, v)) = CONSTANTS.iter().find(|c| c.0 == name) {
                return self.node(Node::Num(v));
            }
            self.pos = start;
            return Err(self.err(format!("unknown variable `{name}` (known: {})", self.vars.join(" "))));
        }
        Err(self.err(format!("unexpected `{}`", c as char)))
    }
}

impl Expr {
    /// Parses `text` over the variables `vars`.
    pub fn parse(text: &str, vars: &[String]) -> Result<Self, Error> {
        let text = text.trim();
        if text.len() > MAX_EXPR_LEN {
            return Err(Error::Param(format!("expression longer than {MAX_EXPR_LEN} bytes")));
        }
        if !text.is_ascii() {
            return Err(Error::Param(format!("expression `{text}`: only ASCII is allowed")));
        }
        let mut p = Parser { s: text.as_bytes(), pos: 0, vars, nodes: 0 };
        let root = p.sum(0)?;
        p.skip();
        if p.pos != text.len() {
            return Err(p.err("unexpected text"));
        }
        Ok(Expr { text: text.to_string(), root })
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    /// Evaluates the expression on the CPU (tests, previews).
    pub fn eval(&self, vars: &[f64]) -> f64 {
        fn go(n: &Node, v: &[f64]) -> f64 {
            match n {
                Node::Num(x) => *x,
                Node::Var(i) => v[*i],
                Node::Neg(a) => -go(a, v),
                Node::Bin(op, a, b) => {
                    let (a, b) = (go(a, v), go(b, v));
                    match op {
                        '+' => a + b,
                        '-' => a - b,
                        '*' => a * b,
                        _ => a / b,
                    }
                }
                Node::Call(f, args) => {
                    let a: Vec<f64> = args.iter().map(|x| go(x, v)).collect();
                    match FUNCTIONS[*f].0 {
                        "sin" => a[0].sin(),
                        "cos" => a[0].cos(),
                        "tan" => a[0].tan(),
                        "asin" => a[0].asin(),
                        "acos" => a[0].acos(),
                        "atan" => a[0].atan(),
                        "atan2" => a[0].atan2(a[1]),
                        "abs" => a[0].abs(),
                        "sign" => {
                            if a[0] == 0.0 {
                                0.0
                            } else {
                                a[0].signum()
                            }
                        }
                        "min" => a[0].min(a[1]),
                        "max" => a[0].max(a[1]),
                        "clamp" => a[0].max(a[1]).min(a[2]),
                        "mix" => a[0] + (a[1] - a[0]) * a[2],
                        "step" => (a[1] >= a[0]) as u8 as f64,
                        "smoothstep" => {
                            let t = ((a[2] - a[0]) / (a[1] - a[0])).clamp(0.0, 1.0);
                            t * t * (3.0 - 2.0 * t)
                        }
                        "pow" => a[0].powf(a[1]),
                        "sqrt" => a[0].sqrt(),
                        "exp" => a[0].exp(),
                        "log" => a[0].ln(),
                        "floor" => a[0].floor(),
                        "ceil" => a[0].ceil(),
                        "round" => a[0].round(),
                        _ => a[0] - a[0].floor(),
                    }
                }
            }
        }
        // As on the GPU: NaN and infinities become 0.
        let v = go(&self.root, vars);
        if v.is_finite() {
            v
        } else {
            0.0
        }
    }

    /// The expression as shader code, variables named `gpufx_v_<name>`.
    fn code(&self, vars: &[String], glsl: bool) -> String {
        fn go(n: &Node, vars: &[String], glsl: bool, out: &mut String) {
            match n {
                Node::Num(x) => {
                    // A float literal, exact enough for f32, behind a call: the shader
                    // compiler folds constant expressions and rejects `log(-1.0)` or
                    // `1.0 / 0.0` at compile time, where the expression must just give NaN.
                    let s = format!("{:?}", *x as f32);
                    out.push_str("gpufx_num(");
                    out.push_str(&s);
                    if !s.contains(['.', 'e', 'E']) {
                        out.push_str(".0");
                    }
                    out.push(')');
                }
                Node::Var(i) => {
                    out.push_str("gpufx_v_");
                    out.push_str(&vars[*i]);
                }
                Node::Neg(a) => {
                    out.push_str("(-");
                    go(a, vars, glsl, out);
                    out.push(')');
                }
                Node::Bin(..) => {
                    out.push('(');
                    chain(n, vars, glsl, out);
                    out.push(')');
                }
                Node::Call(f, args) => {
                    let (_, _, wgsl, gl) = FUNCTIONS[*f];
                    out.push_str(if glsl { gl } else { wgsl });
                    out.push('(');
                    for (k, a) in args.iter().enumerate() {
                        if k > 0 {
                            out.push_str(", ");
                        }
                        go(a, vars, glsl, out);
                    }
                    out.push(')');
                }
            }
        }
        // `a + b - c + ...` without nested parentheses: WGSL and GLSL are left associative
        // within one precedence level, and a long chain must not nest the shader deeply.
        fn chain(n: &Node, vars: &[String], glsl: bool, out: &mut String) {
            let Node::Bin(op, a, b) = n else { return go(n, vars, glsl, out) };
            let class = |o: char| matches!(o, '*' | '/');
            match &**a {
                Node::Bin(inner, ..) if class(*inner) == class(*op) => chain(a, vars, glsl, out),
                _ => go(a, vars, glsl, out),
            }
            out.push(' ');
            out.push(*op);
            out.push(' ');
            go(b, vars, glsl, out);
        }
        let mut s = String::new();
        go(&self.root, vars, glsl, &mut s);
        s
    }

    /// The helper every generated function uses, declared once before them.
    pub(crate) fn helper(glsl: bool) -> &'static str {
        if glsl {
            "float gpufx_num(float x) { return x; }\n"
        } else {
            "fn gpufx_num(x: f32) -> f32 { return x; }\n"
        }
    }

    /// `fn gpufx_expr_<name>(<vars>: f32...) -> f32` in WGSL.
    pub(crate) fn wgsl_fn(&self, name: &str, vars: &[String]) -> String {
        let args: Vec<String> = vars.iter().map(|v| format!("gpufx_v_{v}: f32")).collect();
        // NaN and infinities become 0.
        format!(
            "fn gpufx_expr_{name}({}) -> f32 {{ let v = {}; return select(0.0, v, abs(v) <= 3.4028235e38); }}\n",
            args.join(", "),
            self.code(vars, false)
        )
    }

    /// `float gpufx_expr_<name>(float <vars>...)` in GLSL.
    pub(crate) fn glsl_fn(&self, name: &str, vars: &[String]) -> String {
        let args: Vec<String> = vars.iter().map(|v| format!("float gpufx_v_{v}")).collect();
        format!(
            "float gpufx_expr_{name}({}) {{ float v = {}; return abs(v) <= 3.4028235e38 ? v : 0.0; }}\n",
            args.join(", "),
            self.code(vars, true)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vars() -> Vec<String> {
        ["u", "p", "x0"].iter().map(|s| s.to_string()).collect()
    }

    fn eval(text: &str, v: &[f64]) -> f64 {
        Expr::parse(text, &vars()).unwrap().eval(v)
    }

    #[test]
    fn precedence_and_functions() {
        let v = [2.0, 0.5, 1.0];
        assert_eq!(eval("1 + 2 * 3", &v), 7.0);
        assert_eq!(eval("(1 + 2) * 3", &v), 9.0);
        assert_eq!(eval("-u^2", &v), -4.0);
        assert_eq!(eval("2^3^2", &v), 512.0);
        assert_eq!(eval("8 / 2 / 2", &v), 2.0);
        assert_eq!(eval("10 - 2 - 3", &v), 5.0);
        assert_eq!(eval("clamp(u * 3, 0, x0) + mix(0, 10, p)", &v), 6.0);
        assert_eq!(eval("1.5e1 + .5", &v), 15.5);
        assert!((eval("sin(pi / 2) + fract(2.25)", &v) - 1.25).abs() < 1e-12);
    }

    #[test]
    fn rejects_what_is_not_math() {
        let err = |t: &str| Expr::parse(t, &vars()).unwrap_err().to_string();
        assert!(err("u +").contains("unexpected end"));
        assert!(err("q * 2").contains("unknown variable `q`"));
        assert!(err("textureLoad(u)").contains("unknown function `textureLoad`"));
        assert!(err("min(u)").contains("min takes 2 argument(s), got 1"));
        assert!(err("u; }").contains("unexpected text"));
        assert!(err("(((u").contains("expected `)`"));
        assert!(err("1e999").contains("out of range"));
        assert!(err(&"(".repeat(40)).contains("deeper"));
        assert!(err(&"u+".repeat(600)).contains("longer than"));
        assert!(err(&vec!["u"; 400].join("+")).contains("terms"));
        assert!(err("u é").contains("ASCII"));
    }

    #[test]
    fn shader_code_is_generated_from_the_tree() {
        let e = Expr::parse("x0 + 0.05*sin(6.28*u) - atan2(p, 1) + 2", &vars()).unwrap();
        let w = e.wgsl_fn("path_x", &vars());
        assert_eq!(
            w,
            "fn gpufx_expr_path_x(gpufx_v_u: f32, gpufx_v_p: f32, gpufx_v_x0: f32) -> f32 { let v = (gpufx_v_x0 + (gpufx_num(0.05) * sin((gpufx_num(6.28) * gpufx_v_u))) - atan2(gpufx_v_p, gpufx_num(1.0)) + gpufx_num(2.0)); return select(0.0, v, abs(v) <= 3.4028235e38); }\n"
        );
        // A long chain stays flat: one pair of parentheses.
        let long = Expr::parse(&vec!["u"; 250].join("+"), &vars()).unwrap().code(&vars(), false);
        assert_eq!(long.matches('(').count(), 1);
        assert_eq!(Expr::parse("2 - (1 - u)", &vars()).unwrap().code(&vars(), false), "(gpufx_num(2.0) - (gpufx_num(1.0) - gpufx_v_u))");
        assert_eq!(Expr::parse("log(-1) + 1/0", &vars()).unwrap().eval(&[0.0; 3]), 0.0);
        assert!(e.glsl_fn("path_x", &vars()).contains("atan(gpufx_v_p, gpufx_num(1.0))"));
    }
}
