# Hardware and OS requirements

[Tiếng Việt](REQUIREMENTS-vi.md) · [README](../README.md)

Minimums come from the code (gpufx, wgpu-hal 30.0.1, FFmpeg 9) unless marked *not verified*. Example GPU
families come from public vendor/Microsoft tables, not from tests here.

## Windows

| Requirement | Minimum | Source |
| --- | --- | --- |
| OS | Windows 10 64-bit | Rust 1.78+ `x86_64-pc-windows-*` targets need Windows 10 (Rust platform support doc); crates need Rust 1.88 (`crates/*/Cargo.toml` `rust-version`). FFmpeg 9 minimum: *not verified* |
| D3D12 feature level | 11_0 | `wgpu-hal-30.0.1/src/dx12/adapter.rs:93` (device created at FL 11_0) |
| Resource binding tier | Tier 2 (Tier 1 adapters are skipped) | `wgpu-hal-30.0.1/src/dx12/adapter.rs:243-251` |
| Shader model | 5.1 (higher used when present) | `wgpu-hal-30.0.1/src/dx12/adapter.rs:345-385` |
| D3D11 frames | Windows 10 1703+ (`ID3D11Device5`, D3D11.4 shared fences) | `crates/gpufx-core/src/d3d12.rs:191-218` |
| `dxcompiler.dll` | Optional: only the D3D12 DXIL shader cache | [DESIGN.md](DESIGN.md) (shader cache, D3D12) |

Example GPUs meeting FL 11_0 + tier 2 (from public D3D12 tier tables, *not verified* on hardware except the
NVIDIA RTX 4060 and Intel UHD of the tests): NVIDIA Kepler (GTX 600/700) and later, AMD GCN (HD 7000) and later,
Intel Gen9 (Skylake) and later. Intel Haswell/Broadwell are tier 1, so wgpu does not
expose them.

Tested: D3D12 and D3D11 frames on NVIDIA RTX 4060 Laptop and Intel UHD Graphics (RaptorLake-S, driver
101.7082), Windows 11. CI on Windows only builds (fmt, clippy): see `.github/workflows/ci.yml`.

## Linux (Vulkan)

| Requirement | Minimum | Source |
| --- | --- | --- |
| Vulkan API (frames from FFmpeg) | 1.1 | `crates/gpufx-core/src/vulkan.rs:418-420` |
| Vulkan API asked by FFmpeg 9 | 1.3 | `external/FFmpeg/libavutil/hwcontext_vulkan.c:1203` |
| Queue family | graphics + compute | `crates/gpufx-core/src/vulkan.rs:458-465` |
| Timeline semaphores | required | `crates/gpufx-core/src/vulkan.rs:829-836`, `hwcontext_vulkan.c:327,357` |
| wgpu Vulkan | 1.0 + `VK_KHR_maintenance1` (core in 1.1) | `wgpu-hal-30.0.1/src/vulkan/adapter.rs:1227-1229` |
| glibc (linux64 bundle) | 2.35 (Ubuntu 22.04 build image) | `docker/linux64.Dockerfile:2` |

Drivers: NVIDIA proprietary, Mesa RADV (AMD), Mesa ANV (Intel), lavapipe (CPU; CI and VM only). Linux has only
run on lavapipe; real GPUs on Linux are *not verified*.

## macOS (Metal)

| Requirement | Minimum | Source |
| --- | --- | --- |
| VideoToolbox frames | Apple silicon (unified memory) | `crates/gpufx-core/src/videotoolbox.rs:118-124` |
| VideoToolbox formats | nv12, p010le | [DESIGN.md](DESIGN.md) (VideoToolbox frames) |
| macOS version | 11.0 on Apple silicon (Rust `aarch64-apple-darwin` minimum); wgpu Metal minimum *not verified* | Rust platform support doc |
| Metal GPU family | *not verified* (wgpu checks families only for optional features: `wgpu-hal-30.0.1/src/metal/adapter.rs:650-741`) | |

No Mac device: only `cargo test` on the CI macOS runner; the VideoToolbox path is untested.

## Known issues

| Platform | Issue | See |
| --- | --- | --- |
| Intel GPU, Windows, FFmpeg 9 Vulkan frames | Host image copy bugs in `hwupload`/`hwdownload` | [INTEL_VULKAN.md](INTEL_VULKAN.md) |
| Windows hosted CI | WARP is the only adapter; shaders run on the CPU and take minutes, so no tests run there | `.github/workflows/ci.yml` |
| Linux CI / VM | lavapipe is a CPU driver: correct but slow | [README](../README.md#tests) |
