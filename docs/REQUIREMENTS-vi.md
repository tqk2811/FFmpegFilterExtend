# Yêu cầu phần cứng và hệ điều hành

[English](REQUIREMENTS.md) · [README](../README-vi.md)

Các mức tối thiểu lấy từ code (gpufx, wgpu-hal 30.0.1, FFmpeg 9), trừ chỗ ghi *chưa kiểm chứng*. Dòng GPU ví dụ
lấy từ bảng công khai của hãng/Microsoft, không phải từ test ở đây.

## Windows

| Yêu cầu | Tối thiểu | Nguồn |
| --- | --- | --- |
| OS | Windows 10 64-bit | Target `x86_64-pc-windows-*` của Rust 1.78+ cần Windows 10 (tài liệu platform support của Rust); crate cần Rust 1.88 (`rust-version` trong `crates/*/Cargo.toml`). Mức tối thiểu của FFmpeg 9: *chưa kiểm chứng* |
| D3D12 feature level | 11_0 | `wgpu-hal-30.0.1/src/dx12/adapter.rs:93` (tạo device ở FL 11_0) |
| Resource binding tier | Tier 2 (adapter tier 1 bị bỏ qua) | `wgpu-hal-30.0.1/src/dx12/adapter.rs:243-251` |
| Shader model | 5.1 (có cao hơn thì dùng) | `wgpu-hal-30.0.1/src/dx12/adapter.rs:345-385` |
| Frame D3D11 | Windows 10 1703+ (`ID3D11Device5`, shared fence D3D11.4) | `crates/gpufx-core/src/d3d12.rs:191-218` |
| `dxcompiler.dll` | Tuỳ chọn: chỉ cho shader cache DXIL D3D12 | [DESIGN-vi.md](DESIGN-vi.md) (shader cache, D3D12) |

GPU ví dụ đạt FL 11_0 + tier 2 (theo bảng tier D3D12 công khai, *chưa kiểm chứng* trên máy thật, trừ NVIDIA RTX 4060
và Intel UHD đã chạy test): NVIDIA Kepler (GTX 600/700) trở lên, AMD GCN (HD 7000) trở lên, Intel Gen9
(Skylake) trở lên. Intel Haswell/Broadwell là tier 1 nên wgpu không nhận.

Đã chạy: frame D3D12 và D3D11 trên NVIDIA RTX 4060 Laptop và Intel UHD Graphics (RaptorLake-S, driver 101.7082),
Windows 11. CI trên Windows chỉ build (fmt, clippy): xem `.github/workflows/ci.yml`.

## Linux (Vulkan)

| Yêu cầu | Tối thiểu | Nguồn |
| --- | --- | --- |
| Vulkan API (frame từ FFmpeg) | 1.1 | `crates/gpufx-core/src/vulkan.rs:418-420` |
| Vulkan API FFmpeg 9 xin | 1.3 | `external/FFmpeg/libavutil/hwcontext_vulkan.c:1203` |
| Họ queue | graphics + compute | `crates/gpufx-core/src/vulkan.rs:458-465` |
| Timeline semaphore | bắt buộc | `crates/gpufx-core/src/vulkan.rs:829-836`, `hwcontext_vulkan.c:327,357` |
| wgpu Vulkan | 1.0 + `VK_KHR_maintenance1` (có sẵn trong 1.1) | `wgpu-hal-30.0.1/src/vulkan/adapter.rs:1227-1229` |
| glibc (bundle linux64) | 2.35 (image build Ubuntu 22.04) | `docker/linux64.Dockerfile:2` |

Driver: NVIDIA proprietary, Mesa RADV (AMD), Mesa ANV (Intel), lavapipe (CPU; chỉ CI và VM). Linux mới chạy trên
lavapipe; GPU thật trên Linux *chưa kiểm chứng*.

## macOS (Metal)

| Yêu cầu | Tối thiểu | Nguồn |
| --- | --- | --- |
| Frame VideoToolbox | Apple silicon (unified memory) | `crates/gpufx-core/src/videotoolbox.rs:118-124` |
| Định dạng VideoToolbox | nv12, p010le | [DESIGN-vi.md](DESIGN-vi.md) (frame VideoToolbox) |
| Phiên bản macOS | 11.0 trên Apple silicon (tối thiểu của target Rust `aarch64-apple-darwin`); mức tối thiểu của wgpu Metal *chưa kiểm chứng* | Tài liệu platform support của Rust |
| Metal GPU family | *chưa kiểm chứng* (wgpu chỉ kiểm family cho tính năng tuỳ chọn: `wgpu-hal-30.0.1/src/metal/adapter.rs:650-741`) | |

Không có máy Mac: chỉ chạy `cargo test` trên runner macOS của CI; đường VideoToolbox chưa chạy thật.

## Lỗi đã biết

| Nền tảng | Lỗi | Xem |
| --- | --- | --- |
| GPU Intel, Windows, frame Vulkan FFmpeg 9 | Lỗi host image copy trong `hwupload`/`hwdownload` | [INTEL_VULKAN-vi.md](INTEL_VULKAN-vi.md) |
| CI Windows hosted | WARP là adapter duy nhất; shader chạy bằng CPU mất nhiều phút nên không chạy test | `.github/workflows/ci.yml` |
| CI Linux / VM | lavapipe là driver CPU: đúng nhưng chậm | [README](../README-vi.md#test) |
