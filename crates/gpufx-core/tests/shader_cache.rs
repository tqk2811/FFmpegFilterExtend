//! On-disk shader cache: files appear, are read back by a new device, and a corrupt file
//! is tolerated: pipeline caches (`.gpucache`, Vulkan) and DXIL (`.dxil`, D3D12 with
//! `dxcompiler.dll`). Skipped without a device, or on backends with neither.

mod common;

use std::path::{Path, PathBuf};

use gpufx_core::{Effect, FrameInfo, GpuContext, Image, ImageMut, Package};

fn example() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/effects");
    let mut all: Vec<_> = std::fs::read_dir(dir).unwrap().map(|e| e.unwrap().path()).collect();
    all.sort();
    all.into_iter().next().unwrap()
}

fn cache_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("gpufx-cache-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn files(dir: &Path) -> Vec<PathBuf> {
    let mut v: Vec<_> = std::fs::read_dir(dir).map(|d| d.map(|e| e.unwrap().path()).collect()).unwrap_or_default();
    v.retain(|p| p.extension().is_some_and(|x| x == "gpucache" || x == "dxil"));
    v.sort();
    v
}

/// Runs the example once on a new device using `dir`; `None` when there is no cache.
fn run(dir: &Path) -> Option<(Vec<u8>, gpufx_core::ShaderCacheStats)> {
    let ctx = match GpuContext::with_shader_cache(common::backend(), Some(dir)) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("skipping: {e}");
            return None;
        }
    };
    ctx.shader_cache_stats()?;
    let (w, h) = (16, 16);
    let src: Vec<u8> = (0..w * h * 4).map(|i| (i * 7) as u8).collect();
    let mut fx = Effect::new(ctx.clone(), Package::open(example()).unwrap()).unwrap();
    let inputs = vec![Image { data: &src, width: w, height: h, stride: w * 4 }; fx.input_count()];
    let mut out = vec![0u8; (w * h * 4) as usize];
    fx.process(&inputs, ImageMut { data: &mut out, width: w, height: h, stride: w * 4 }, &FrameInfo::new(0.5, 3)).unwrap();
    let stats = ctx.shader_cache_stats().unwrap();
    Some((out, stats))
}

#[test]
fn second_device_reads_the_cache_and_corrupt_files_are_tolerated() {
    let dir = cache_dir("main");
    let Some((first, s1)) = run(&dir) else {
        eprintln!("skipping: no on-disk pipeline cache on this backend");
        return;
    };
    assert_eq!(s1.loaded, 0);
    let written = files(&dir);
    assert!(!written.is_empty(), "cache directory stays empty");

    let (second, s2) = run(&dir).unwrap();
    assert!(s2.loaded >= written.len() as u64, "{s2:?}");
    assert_eq!(first, second);

    for f in &written {
        std::fs::write(f, b"definitely not a pipeline cache").unwrap();
    }
    let (third, _) = run(&dir).unwrap();
    assert_eq!(first, third);
    // Rewritten with real data.
    assert!(files(&dir).iter().all(|f| std::fs::read(f).unwrap() != b"definitely not a pipeline cache"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn unwritable_directory_only_disables_the_cache() {
    // A regular file where the directory should be.
    let dir = cache_dir("blocked");
    std::fs::write(&dir, b"x").unwrap();
    if let Ok(ctx) = GpuContext::with_shader_cache(common::backend(), Some(&dir)) {
        assert!(ctx.shader_cache_stats().is_none());
        Effect::new(ctx, Package::open(example()).unwrap()).unwrap();
    }
    let _ = std::fs::remove_file(&dir);
}

#[test]
fn checksum_mismatch_is_ignored_and_rewritten() {
    let dir = cache_dir("checksum");
    let Some((first, _)) = run(&dir) else { return };
    let written = files(&dir);
    let good: Vec<Vec<u8>> = written.iter().map(|f| std::fs::read(f).unwrap()).collect();
    for (f, data) in written.iter().zip(&good) {
        let mut bad = data.clone();
        bad[0] ^= 0xff; // blob changed, trailing SHA-256 no longer matches
        std::fs::write(f, bad).unwrap();
    }
    let (second, stats) = run(&dir).unwrap();
    assert_eq!(stats.loaded, 0, "{stats:?}");
    assert!(stats.written >= written.len() as u64, "{stats:?}");
    assert_eq!(first, second);
    let (_, stats) = run(&dir).unwrap();
    assert!(stats.loaded >= written.len() as u64, "{stats:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn world_writable_directory_is_refused() {
    use std::os::unix::fs::PermissionsExt;
    let dir = cache_dir("public");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o777)).unwrap();
    if let Ok(ctx) = GpuContext::with_shader_cache(common::backend(), Some(&dir)) {
        assert!(ctx.shader_cache_stats().is_none());
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn conversion_pipelines_go_through_the_cache() {
    // A context compiles its conversion passes before any effect is opened.
    let dir = cache_dir("convert");
    let open = || match GpuContext::with_shader_cache(common::backend(), Some(&dir)) {
        Ok(ctx) => ctx.shader_cache_stats(),
        Err(e) => {
            eprintln!("skipping: {e}");
            None
        }
    };
    let Some(first) = open() else { return };
    assert_eq!(first.loaded, 0, "{first:?}");
    assert!(first.written >= 3, "{first:?}");
    let written = files(&dir).len() as u64;
    let second = open().unwrap();
    assert!(second.loaded >= first.written, "{second:?}");
    assert_eq!(files(&dir).len() as u64, written);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Every example on a new D3D12 device using `dir` (no cache when `None`): their outputs,
/// the cache counters and the time to open the context and the effects.
#[cfg(windows)]
fn run_all_d3d12(dir: Option<&Path>) -> Option<(Vec<Vec<u8>>, Option<gpufx_core::ShaderCacheStats>, std::time::Duration)> {
    let start = std::time::Instant::now();
    let ctx = GpuContext::with_shader_cache(gpufx_core::Backend::Dx12, dir).map_err(|e| eprintln!("skipping: {e}")).ok()?;
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/effects");
    let mut all: Vec<_> = std::fs::read_dir(root).unwrap().map(|e| e.unwrap().path()).collect();
    all.sort();
    let effects: Vec<Effect> = all.into_iter().map(|p| Effect::new(ctx.clone(), Package::open(p).unwrap()).unwrap()).collect();
    let opened = start.elapsed();
    let (w, h) = (16, 16);
    let src: Vec<u8> = (0..w * h * 4).map(|i| (i * 7) as u8).collect();
    let outputs = effects
        .into_iter()
        .map(|mut fx| {
            let inputs = vec![Image { data: &src, width: w, height: h, stride: w * 4 }; fx.input_count()];
            let mut out = vec![0u8; (w * h * 4) as usize];
            fx.process(&inputs, ImageMut { data: &mut out, width: w, height: h, stride: w * 4 }, &FrameInfo::new(0.5, 3)).unwrap();
            out
        })
        .collect();
    Some((outputs, ctx.shader_cache_stats(), opened))
}

#[cfg(windows)]
#[test]
fn d3d12_dxil_cache_gives_the_pixels_of_the_normal_path() {
    let dir = cache_dir("dxil");
    let Some((cold, Some(s1), cold_time)) = run_all_d3d12(Some(&dir)) else {
        eprintln!("skipping: no D3D12 device or no dxcompiler.dll");
        return;
    };
    let dxil = || std::fs::read_dir(&dir).unwrap().filter(|e| e.as_ref().unwrap().path().extension().is_some_and(|x| x == "dxil")).count();
    // Pipelines met twice in one run (same shader, same layout) are read back already.
    assert!(s1.written > 0 && dxil() as u64 == s1.written, "{s1:?}");
    let (warm, s2, warm_time) = run_all_d3d12(Some(&dir)).unwrap();
    let s2 = s2.unwrap();
    assert_eq!(s2.written, 0, "{s2:?}");
    assert_eq!(s2.loaded, s1.loaded + s1.written, "{s2:?}");
    let (plain, none, plain_time) = run_all_d3d12(None).unwrap();
    assert!(none.is_none());
    eprintln!("D3D12 contexts and examples opened: no cache {plain_time:?}, cold cache {cold_time:?}, warm cache {warm_time:?}");
    assert_eq!(cold, plain);
    assert_eq!(warm, plain);

    // A file with a good checksum that the D3D12 runtime refuses is compiled again.
    for e in std::fs::read_dir(&dir).unwrap() {
        let path = e.unwrap().path();
        if path.extension().is_some_and(|x| x == "dxil") {
            let mut bad = b"DXBC but not really".to_vec();
            bad.extend_from_slice(&sha2::Digest::finalize(sha2::Digest::chain_update(<sha2::Sha256 as sha2::Digest>::new(), &bad)));
            std::fs::write(path, bad).unwrap();
        }
    }
    let (refused, s3, _) = run_all_d3d12(Some(&dir)).unwrap();
    assert_eq!(s3.unwrap().written, s1.written, "{s3:?}");
    assert_eq!(refused, plain);
    let _ = std::fs::remove_dir_all(&dir);
}
