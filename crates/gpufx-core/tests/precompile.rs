//! `gpufx pack --precompile`: the D3D12 shaders inside a package give the pixels of the
//! normal path, and are only used with `GPUFX_TRUST_PRECOMPILED=1`. Its own test binary:
//! it sets that variable for the whole process. Skipped without D3D12 or dxcompiler.dll.
#![cfg(windows)]

use std::path::PathBuf;

use gpufx_core::{Backend, Effect, FrameInfo, GpuContext, Image, ImageMut, Package};

/// Every packed example on a new D3D12 device without cache directory: outputs and
/// shader cache counters.
fn run_all(packages: &[Package]) -> (Vec<Vec<u8>>, Option<gpufx_core::ShaderCacheStats>) {
    let ctx = GpuContext::with_shader_cache(Backend::Dx12, None).unwrap();
    let (w, h) = (16, 16);
    let src: Vec<u8> = (0..w * h * 4).map(|i| (i * 7) as u8).collect();
    let outputs = packages
        .iter()
        .map(|pkg| {
            let mut fx = Effect::new(ctx.clone(), pkg.clone()).unwrap();
            let inputs = vec![Image { data: &src, width: w, height: h, stride: w * 4 }; fx.input_count()];
            let mut out = vec![0u8; (w * h * 4) as usize];
            fx.process(&inputs, ImageMut { data: &mut out, width: w, height: h, stride: w * 4 }, &FrameInfo::new(0.5, 3)).unwrap();
            out
        })
        .collect();
    (outputs, ctx.shader_cache_stats())
}

#[test]
fn precompiled_shaders_are_used_only_when_trusted() {
    std::env::remove_var("GPUFX_SHADER_CACHE");
    std::env::remove_var("GPUFX_TRUST_PRECOMPILED");
    if let Err(e) = GpuContext::new(Backend::Dx12) {
        eprintln!("skipping: {e}");
        return;
    }
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/effects");
    let mut dirs: Vec<_> = std::fs::read_dir(root)
        .unwrap()
        .map(|g| g.unwrap().path())
        .filter(|g| g.is_dir())
        .flat_map(|g| std::fs::read_dir(g).unwrap())
        .map(|e| e.unwrap().path())
        .collect();
    dirs.sort();
    let out = std::env::temp_dir().join(format!("gpufx-precompile-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&out);
    std::fs::create_dir_all(&out).unwrap();
    let mut packages = Vec::new();
    let mut passes = 0;
    for dir in &dirs {
        let zip = out.join(format!("{}.zip", dir.file_name().unwrap().to_string_lossy()));
        match Package::pack(dir, &zip, true) {
            Ok(n) => assert!(n > 0),
            Err(e) => {
                eprintln!("skipping: {e}");
                return;
            }
        }
        let pkg = Package::open(&zip).unwrap();
        passes += pkg.manifest.passes.len() as u64;
        packages.push(pkg);
    }

    let (plain, none) = run_all(&packages);
    assert!(none.is_none(), "untrusted blobs need no cache: {none:?}");

    std::env::set_var("GPUFX_TRUST_PRECOMPILED", "1");
    let (trusted, stats) = run_all(&packages);
    std::env::remove_var("GPUFX_TRUST_PRECOMPILED");
    let stats = stats.expect("a cache for the packaged DXIL");
    // Every 8-bit pipeline of every package came from its DXIL.
    assert_eq!(stats.precompiled, passes, "{stats:?}");
    assert_eq!((stats.loaded, stats.written), (0, 0), "{stats:?}");
    assert_eq!(trusted, plain);
    let _ = std::fs::remove_dir_all(&out);
}
