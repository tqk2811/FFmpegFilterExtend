//! Puts the exact versions of the wgpu crates that compile shaders (from the workspace
//! `Cargo.lock`) into `GPUFX_WGPU_VERSIONS`, part of the shader cache key: a patch release
//! of naga or wgpu-hal can change the generated code or the root signature layout.

use std::path::{Path, PathBuf};

/// Used when the lock of this crate's own workspace is not at hand (built as a git or
/// vendored dependency) or does not list the crates.
fn fallback() -> String {
    format!("wgpu 30;gpufx {}", std::env::var("CARGO_PKG_VERSION").unwrap_or_default())
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let versions = workspace_lock(&dir)
        .and_then(|lock| {
            println!("cargo:rerun-if-changed={}", lock.display());
            let text = std::fs::read_to_string(&lock).ok()?;
            let parts: Option<Vec<String>> =
                ["naga", "wgpu-core", "wgpu-hal"].iter().map(|name| Some(format!("{name} {}", versions_of(&text, name)?))).collect();
            Some(parts?.join(";"))
        })
        .unwrap_or_else(fallback);
    println!("cargo:rustc-env=GPUFX_WGPU_VERSIONS={versions}");
}

/// The `Cargo.lock` of the workspace this crate belongs to: the nearest ancestor whose
/// `Cargo.toml` has `[workspace]` (as cargo looks it up), only if it lists this crate as a
/// member (or is the crate itself). A lock of an unrelated outer project is not used.
fn workspace_lock(crate_dir: &Path) -> Option<PathBuf> {
    for root in crate_dir.ancestors() {
        let Ok(toml) = std::fs::read_to_string(root.join("Cargo.toml")) else { continue };
        if !toml.lines().any(|l| l.trim() == "[workspace]") {
            continue;
        }
        let rel = crate_dir.strip_prefix(root).ok()?.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/");
        let member = rel.is_empty() || toml.contains(&format!("\"{rel}\""));
        let lock = root.join("Cargo.lock");
        return (member && lock.is_file()).then_some(lock);
    }
    None
}

/// Every version of package `name` in the lock file, comma separated; `None` if absent.
/// Fields of a `[[package]]` block may come in any order.
fn versions_of(lock: &str, name: &str) -> Option<String> {
    let wanted = format!("\"{name}\"");
    let found: Vec<&str> = lock
        .split("[[package]]")
        .skip(1)
        .filter_map(|block| {
            let field = |key: &str| {
                block.lines().find_map(|l| {
                    let (k, v) = l.split_once('=')?;
                    (k.trim() == key).then(|| v.trim())
                })
            };
            (field("name")? == wanted).then(|| field("version")).flatten().map(|v| v.trim_matches('"'))
        })
        .collect();
    (!found.is_empty()).then(|| found.join(","))
}
