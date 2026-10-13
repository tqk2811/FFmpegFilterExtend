//! Puts the exact versions of the wgpu crates that compile shaders (from the workspace
//! `Cargo.lock`) into `GPUFX_WGPU_VERSIONS`, part of the shader cache key: a patch release
//! of naga or wgpu-hal can change the generated code or the root signature layout.

use std::path::Path;

fn main() {
    let dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let lock = Path::new(&dir).ancestors().map(|d| d.join("Cargo.lock")).find(|p| p.is_file());
    let versions = match &lock {
        Some(lock) => {
            println!("cargo:rerun-if-changed={}", lock.display());
            let text = std::fs::read_to_string(lock).unwrap_or_default();
            ["naga", "wgpu-core", "wgpu-hal"].map(|name| format!("{name} {}", versions_of(&text, name))).join(";")
        }
        // Built as a dependency without the lock file at hand: only the major version.
        None => "wgpu 30".to_string(),
    };
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rustc-env=GPUFX_WGPU_VERSIONS={versions}");
}

/// Every version of package `name` in the lock file, comma separated.
fn versions_of(lock: &str, name: &str) -> String {
    let wanted = format!("name = \"{name}\"");
    let mut lines = lock.lines();
    let mut found = Vec::new();
    while let Some(line) = lines.next() {
        if line.trim() == wanted {
            if let Some(v) = lines.next().and_then(|l| l.trim().strip_prefix("version = ")) {
                found.push(v.trim_matches('"').to_string());
            }
        }
    }
    if found.is_empty() {
        "unknown".to_string()
    } else {
        found.join(",")
    }
}
