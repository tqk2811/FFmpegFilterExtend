# Intel Vulkan on Windows: host image copy bugs (FFmpeg 9)

[Tiếng Việt](INTEL_VULKAN-vi.md) · [README](../README.md)

Short version: on an Intel GPU under Windows, upload with `gpufx_upload` and read back with `gpufx_download`
(or plain `hwdownload` after a `gpufx`) instead of `hwupload` / `hwdownload` around FFmpeg's own frames.
`gpufx` refuses `hwupload` frames there with a message that says so.

## Cause

FFmpeg 9 enables `VK_EXT_host_image_copy` when the device has it and has a resizable BAR
(`libavutil/hwcontext_vulkan.c`, extension list and the ReBAR check in the device setup). Every Vulkan frames
context then gets `VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT` (`vulkan_frames_init`, except on NVIDIA and MoltenVK),
whatever usage the caller set, and `av_hwframe_transfer_data()` (`hwupload`, `hwdownload`) copies with
`vkCopyMemoryToImageEXT` / `vkCopyImageToMemoryEXT` instead of a GPU copy through a staging buffer.
FFmpeg 8.0.1 does not do this.

The Intel Windows driver (tested: UHD Graphics RaptorLake-S, driver 101.7082) gets two cases wrong:

- **A. Allocation failure.** Optimal-tiling images with host-transfer usage that are single-plane (`rgba`,
  `bgra`, and every plane with `disable_multiplane=1`) fail `vkAllocateMemory` with
  `VK_ERROR_OUT_OF_HOST_MEMORY`. Symptom: `hwupload` stops with
  `Failed to allocate memory: VK_ERROR_OUT_OF_HOST_MEMORY` / `vulkan_pool_alloc failed with error -12`.
  The same images allocate with linear tiling.
- **B. Silent corruption.** Host copies to and from multi-planar images (`nv12`, `yuv420p` as one `VkImage`)
  put chroma data into plane 0. Even `hwupload,hwdownload` with nothing in between returns a different picture:
  about a quarter of the luma bytes differ, plus half of the nv12 UV bytes or the whole U plane of yuv420p
  (it holds V data). No error is printed.

The same commands are bit-exact on an NVIDIA RTX 4060 (FFmpeg leaves host copy off there) and with FFmpeg 8.0.1
on the Intel GPU. `gpufx_upload` / `gpufx_download` record GPU copies through their own buffers and are
bit-exact on the Intel GPU.

Evidence (FFmpeg `03d9533176`, 320x180 nv12 / yuv420p, Intel = `vk:1`):

| Device options | nv12 round trip | yuv420p round trip | rgba |
| --- | --- | --- | --- |
| none | differs (B) | differs (B) | allocation fails (A) |
| `disable_multiplane=1` | allocation fails (A) | allocation fails (A) | allocation fails (A) |
| `linear_images=1` | differs (B) | differs (B) | works |
| `disable_multiplane=1,linear_images=1` | identical | identical | works |

## What gpufx does about it

- Every Vulkan frames context `gpufx`, `gpufx_upload` and `gpufx_download` create (output frames, frames for
  software inputs, blank frames for late inputs, the upload pool) drops `VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT`
  right after `av_hwframe_ctx_init()` (`gpufx_hwframe_ctx_init` in `ffmpeg/vf_gpufx_vk.h`). FFmpeg adds the
  flag whatever usage is set beforehand, but the images are only created at the first frame, so they never get
  it. Their memory allocates (no bug A) and `hwdownload` of them uses FFmpeg's buffer copy (no bug B).
  FFmpeg's sources are not patched.
- A `gpufx` input whose frames were made by FFmpeg with host-transfer usage on the Intel Windows driver, with
  optimal tiling or multi-planar (so `hwupload` gives a failed or corrupted frame), is refused when the graph is
  configured. The error names the input and the fixes below. Decoder frames are not affected (the GPU writes
  them), and linear single-plane frames (`disable_multiplane=1,linear_images=1`) are accepted.

## Use gpufx_upload / gpufx_download

```sh
ffmpeg -init_hw_device vulkan=vk:1,disable_multiplane=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,gpufx_upload,gpufx=effect=vignette.zip,gpufx_download,format=nv12" out.mp4
```

Software inputs given straight to `gpufx` are uploaded by `gpufx` itself and are fine too, and `hwdownload`
after `gpufx` reads `gpufx`'s own frames correctly. Only frames FFmpeg allocates (`hwupload`, `hwdownload` of
`hwupload` frames, the `*_vulkan` filters' own outputs) go through the broken host copy.

This is the recommended setup on every GPU, not only Intel: on NVIDIA `gpufx_upload` / `gpufx_download`
pipeline the copies and are faster than `hwupload` / `hwdownload` (see [BENCHMARK.md](BENCHMARK.md)).

## Plain FFmpeg: disable_multiplane=1,linear_images=1

For graphs that must use `hwupload` / `hwdownload` (other Vulkan filters, no `gpufx` in the graph), open the
device with both options:

```sh
ffmpeg -init_hw_device vulkan=vk:1,disable_multiplane=1,linear_images=1 -filter_hw_device vk -i a.mp4 \
  -vf "format=nv12,hwupload,gpufx=effect=vignette.zip,hwdownload,format=nv12" out.mp4
```

Both are needed:

- `disable_multiplane=1` alone gives one single-plane image per plane, still with optimal tiling: bug A, the
  allocation fails.
- `linear_images=1` alone gives linear multi-planar images: bug B, the chroma is still corrupted.
- Together the images are linear and single-plane, and the round trips above were bit-exact.

The cost: linear images are slower for the GPU to sample and write than optimal ones (tiled memory layout is
what the texture units are built for), and every plane is a separate image. `gpufx` accepts such frames.
The whole gpufx test suite passes on the Intel GPU with these options and `hwupload` (`VK_DEVICE_OPTS=disable_multiplane=1,linear_images=1 VK_ADAPTER=1 sh scripts/test-bundle.sh ...`: 157 ok, 2026-10-14).

The other way out on Windows is D3D11 frames (`-init_hw_device d3d11va=dx -filter_hw_device dx`), which `gpufx`
also reads and writes.

## Status upstream

FFmpeg: reported as [FFmpeg issue #25063](https://code.ffmpeg.org/FFmpeg/FFmpeg/issues/25063) (host image copy enabled on a driver that gets
it wrong). Intel (bugs A and B): reported as [IGCIT issue #1587](https://github.com/IGCIT/Intel-GPU-Community-Issue-Tracker-IGCIT/issues/1587). When a fixed driver or FFmpeg is out, the refusal in `gpufx` and the
test workaround can go (backlog item, in Vietnamese: [Backlog-vi.md](Backlog-vi.md)).

## How to re-check

```sh
# in.yuv from any FFmpeg with lavfi (the bundles have no source filters)
ffmpeg -v error -f lavfi -i testsrc2=s=320x180 -frames:v 1 -pix_fmt nv12 -f rawvideo in.yuv
ffmpeg -v error -init_hw_device vulkan=vk:1 -filter_hw_device vk -f rawvideo -pix_fmt nv12 -s 320x180 -i in.yuv \
  -vf "hwupload,hwdownload,format=nv12" -f rawvideo out.yuv
md5sum in.yuv out.yuv  # B: must match
# A: rgba allocation (fails with VK_ERROR_OUT_OF_HOST_MEMORY on an affected driver)
ffmpeg -v error -init_hw_device vulkan=vk:1 -filter_hw_device vk -f rawvideo -pix_fmt nv12 -s 320x180 -i in.yuv \
  -vf "format=rgba,hwupload,hwdownload,format=rgba" -f null -
# Does the device use host image copy, and which driver is it?
ffmpeg -v verbose -init_hw_device vulkan=vk:1 2>&1 | grep -E "selected|host_image_copy"
# The gpufx tests on that device (they switch to gpufx_upload and check the refusal)
VK_ADAPTER=1 DX_ADAPTER=1 REQUIRE_D3D=1 sh scripts/test-bundle.sh dist/win64
```
