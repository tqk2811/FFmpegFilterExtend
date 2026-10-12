//! `gpufx` command line: inspect, pack and test effect packages without FFmpeg.

use std::io::Write;
use std::path::Path;
use std::process::ExitCode;

use gpufx_core::manifest::SizeRule;
use gpufx_core::{Backend, Effect, GpuContext, Image, Package, StreamInfo};

const USAGE: &str = "\
usage:
  gpufx info  <package>
  gpufx check <package> [--backend ...]   compile every shader and report errors
  gpufx pack <dir> <out.zip>
  gpufx run  <package> -i <in.png> [-i <in2.png>...] -o <out.png>
             [-p name=value]... [--backend auto|vulkan|dx12|metal|gl] [--time seconds]";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("info") if args.len() == 2 => info(&args[1]),
        Some("check") if args.len() >= 2 => check(&args[1], &args[2..]),
        Some("pack") if args.len() == 3 => pack(Path::new(&args[1]), Path::new(&args[2])),
        Some("run") if args.len() >= 2 => run(&args[1], &args[2..]),
        _ => Err(USAGE.to_string()),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

fn info(path: &str) -> Result<(), String> {
    let pkg = Package::open(path).map_err(|e| e.to_string())?;
    let m = &pkg.manifest;
    println!("{} ({}) {}", m.name, m.id, m.version);
    if !m.description.is_empty() {
        println!("  {}", m.description);
    }
    println!("inputs:");
    for i in &m.inputs {
        println!("  {} {}", i.name, i.description);
        if !i.formats.is_empty() {
            println!("    formats: {}", i.formats.join(", "));
        }
        for (what, rule) in [("width", &i.width), ("height", &i.height)] {
            if let Some(r) = rule {
                println!("    {what}: {}", describe(r));
            }
        }
        if i.same_size {
            println!("    same size as the first input");
        }
    }
    println!("output formats: {}", m.output.formats.join(", "));
    println!("params:");
    for p in &m.params {
        let default = p.default.as_ref().map(|d| d.to_string()).unwrap_or_else(|| "0".into());
        let range = match (p.min, p.max) {
            (Some(a), Some(b)) => format!(" [{a}..{b}]"),
            _ => String::new(),
        };
        println!("  {} : {:?} = {default}{range}  {}", p.name, p.kind, p.description);
    }
    println!("passes: {}", m.passes.len());
    Ok(())
}

fn describe(r: &SizeRule) -> String {
    let mut parts = Vec::new();
    if let Some(v) = r.min {
        parts.push(format!(">= {v}"));
    }
    if let Some(v) = r.max {
        parts.push(format!("<= {v}"));
    }
    if let Some(v) = r.multiple_of {
        parts.push(format!("multiple of {v}"));
    }
    parts.join(", ")
}

/// FFmpeg name of the pixel format a decoded image has, for the manifest input rules.
fn pix_fmt(img: &image::DynamicImage) -> Option<&'static str> {
    use image::ColorType::*;
    Some(match img.color() {
        L8 => "gray",
        La8 => "ya8",
        Rgb8 => "rgb24",
        Rgba8 => "rgba",
        L16 => "gray16be",
        La16 => "ya16be",
        Rgb16 => "rgb48be",
        Rgba16 => "rgba64be",
        _ => return None,
    })
}

fn check(path: &str, args: &[String]) -> Result<(), String> {
    let backend = match args {
        [] => Backend::Auto,
        [flag, b] if flag == "--backend" => b.parse().map_err(|e: gpufx_core::Error| e.to_string())?,
        _ => return Err(USAGE.to_string()),
    };
    let pkg = Package::open(path).map_err(|e| e.to_string())?;
    let passes = pkg.manifest.passes.len();
    let ctx = GpuContext::new(backend).map_err(|e| e.to_string())?;
    let device = ctx.description();
    Effect::new(ctx, pkg).map_err(|e| e.to_string())?;
    println!("ok: {passes} pass(es) compiled on {device}");
    Ok(())
}

fn pack(dir: &Path, out: &Path) -> Result<(), String> {
    // Validate the manifest and file references before writing anything.
    Package::open(dir).map_err(|e| e.to_string())?;
    let file = std::fs::File::create(out).map_err(|e| e.to_string())?;
    let mut zip = zip::ZipWriter::new(file);
    let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    let mut stack = vec![dir.to_path_buf()];
    let mut files = Vec::new();
    while let Some(d) = stack.pop() {
        for entry in std::fs::read_dir(&d).map_err(|e| e.to_string())? {
            let path = entry.map_err(|e| e.to_string())?.path();
            if path.is_dir() {
                stack.push(path);
            } else {
                files.push(path);
            }
        }
    }
    files.sort();
    for path in files {
        let rel = path.strip_prefix(dir).expect("walked from dir").to_string_lossy().replace('\\', "/");
        zip.start_file(rel, opts).map_err(|e| e.to_string())?;
        zip.write_all(&std::fs::read(&path).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    }
    zip.finish().map_err(|e| e.to_string())?;
    println!("wrote {}", out.display());
    Ok(())
}

fn run(path: &str, args: &[String]) -> Result<(), String> {
    let mut inputs = Vec::new();
    let mut output = None;
    let mut params = Vec::new();
    let mut backend = Backend::Auto;
    let mut time = 0.0;
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let mut value = || it.next().cloned().ok_or_else(|| format!("{flag} needs a value\n{USAGE}"));
        match flag.as_str() {
            "-i" => inputs.push(value()?),
            "-o" => output = Some(value()?),
            "-p" => params.push(value()?),
            "--backend" => backend = value()?.parse().map_err(|e: gpufx_core::Error| e.to_string())?,
            "--time" => time = value()?.parse().map_err(|_| "--time needs a number".to_string())?,
            _ => return Err(format!("unknown argument {flag}\n{USAGE}")),
        }
    }
    let output = output.ok_or_else(|| format!("missing -o\n{USAGE}"))?;

    let pkg = Package::open(path).map_err(|e| e.to_string())?;
    let ctx = GpuContext::new(backend).map_err(|e| e.to_string())?;
    eprintln!("device: {}", ctx.description());
    let mut fx = Effect::new(ctx, pkg).map_err(|e| e.to_string())?;
    for p in &params {
        let (k, v) = p.split_once('=').ok_or_else(|| format!("-p expects name=value, got `{p}`"))?;
        fx.params_mut().set_str(k, v).map_err(|e| e.to_string())?;
    }
    let decoded: Vec<image::DynamicImage> =
        inputs.iter().map(|p| image::open(p).map_err(|e| format!("{p}: {e}"))).collect::<Result<_, _>>()?;
    let streams: Vec<StreamInfo> =
        decoded.iter().map(|i| StreamInfo { format: pix_fmt(i), width: i.width(), height: i.height() }).collect();
    fx.package().manifest.check_inputs(&streams).map_err(|e| e.to_string())?;
    let images: Vec<image::RgbaImage> = decoded.iter().map(|i| i.to_rgba8()).collect();
    let views: Vec<Image> =
        images.iter().map(|i| Image { data: i.as_raw(), width: i.width(), height: i.height(), stride: i.width() * 4 }).collect();
    let (w, h) = views.first().map(|v| (v.width, v.height)).ok_or("need at least one -i")?;
    let mut out = vec![0u8; (w * h * 4) as usize];
    let start = std::time::Instant::now();
    fx.process(&views, &mut out, w * 4, time, 0).map_err(|e| e.to_string())?;
    eprintln!("processed {w}x{h} in {:.1} ms", start.elapsed().as_secs_f64() * 1e3);
    image::RgbaImage::from_raw(w, h, out).expect("sized above").save(&output).map_err(|e| e.to_string())?;
    Ok(())
}
