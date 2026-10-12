/*
 * gpufx: run GPU effect packages (zip with manifest.json + WGSL shaders).
 * SPDX-License-Identifier: MIT
 *
 * Error convention: functions returning int return 0 on success and a negative
 * value on failure; functions returning pointers return NULL on failure.
 * gpufx_last_error() then describes the failure for the calling thread.
 *
 * A GpufxEffect is not thread-safe: use one effect from one thread at a time.
 * Effects opened with the same backend share one GPU device.
 */
#ifndef GPUFX_H
#define GPUFX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GPUFX_API_VERSION 6

typedef struct GpufxEffect GpufxEffect;

/* An RGBA8 image in CPU memory. stride is bytes per row, >= width * 4. */
typedef struct GpufxImage {
    const uint8_t *data;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
} GpufxImage;

/* Where the effect writes its RGBA8 result. stride is bytes per row, >= width * 4. */
typedef struct GpufxOutput {
    uint8_t *data;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
} GpufxOutput;

/*
 * Colour properties of a GpufxFrame. matrix, range and chroma_location only matter for
 * YUV formats; RGB and alpha are always full range.
 */
#define GPUFX_MATRIX_BT601  0 /* also BT.470BG, SMPTE 170M; FFmpeg's guess when unknown */
#define GPUFX_MATRIX_BT709  1
#define GPUFX_MATRIX_BT2020 2 /* non-constant luminance */

#define GPUFX_RANGE_LIMITED 0 /* "tv": luma 16..235, chroma 16..240, scaled for more bits */
#define GPUFX_RANGE_FULL    1 /* "pc", JPEG */

/* Where chroma samples sit in a subsampled format (the AVChromaLocation names). */
#define GPUFX_CHROMA_LEFT       0 /* MPEG-2, H.264: the usual default */
#define GPUFX_CHROMA_CENTER     1 /* MPEG-1, JPEG */
#define GPUFX_CHROMA_TOPLEFT    2
#define GPUFX_CHROMA_TOP        3
#define GPUFX_CHROMA_BOTTOMLEFT 4
#define GPUFX_CHROMA_BOTTOM     5

/*
 * The frame has premultiplied alpha. Effects see straight alpha: the colours are divided
 * by alpha after reading and multiplied again before writing, in RGB.
 */
#define GPUFX_FRAME_PREMULTIPLIED 1u

typedef struct GpufxColor {
    uint32_t matrix;          /* GPUFX_MATRIX_* */
    uint32_t range;           /* GPUFX_RANGE_* */
    uint32_t chroma_location; /* GPUFX_CHROMA_* */
    uint32_t flags;           /* GPUFX_FRAME_* */
} GpufxColor;

/*
 * A frame in CPU memory in one of the formats of gpufx_format_name(), converted to and
 * from RGBA on the GPU. format is the FFmpeg pixel format name ("nv12", "p010le",
 * "yuv420p"...). data and stride (bytes per row, >= the row size) are per plane, in the
 * FFmpeg plane order; unused planes are ignored. Samples above 8 bits are little endian.
 */
typedef struct GpufxFrame {
    const char *format;
    uint32_t width;
    uint32_t height;
    const uint8_t *data[4];
    uint32_t stride[4];
    GpufxColor color;
} GpufxFrame;

/* Where the effect writes its result, as GpufxFrame. */
typedef struct GpufxFrameOut {
    const char *format;
    uint32_t width;
    uint32_t height;
    uint8_t *data[4];
    uint32_t stride[4];
    GpufxColor color;
} GpufxFrameOut;

/* Per-frame values exposed to shaders as globals. */
typedef struct GpufxFrameInfo {
    double time;         /* seconds; globals.time, globals.time_int + globals.time_frac */
    uint64_t frame;      /* frame index; globals.frame */
    double pixel_aspect; /* sample aspect ratio (width / height of a pixel), 1 if unknown */
} GpufxFrameInfo;

/* Properties of one input stream, checked against the manifest rules. */
typedef struct GpufxStreamInfo {
    const char *format; /* FFmpeg pixel format name ("yuv420p"), or NULL if unknown */
    uint32_t width;
    uint32_t height;
} GpufxStreamInfo;

/*
 * Returns GPUFX_API_VERSION of the loaded library. Versions only grow by additions
 * (new functions, constants): a library with a version >= the header's works, an older
 * one does not. A change that breaks existing callers renames the library.
 */
uint32_t gpufx_version(void);

/* Message of the last error on this thread. Never NULL; valid until the next call. */
const char *gpufx_last_error(void);

/*
 * Pixel formats gpufx_effect_process_frames() takes and writes: "rgba", "rgba64le",
 * "nv12", "p010le", "yuv420p", "yuv422p", "yuv444p", their 10-bit "...10le" versions,
 * "yuva420p", "yuva444p". Static strings.
 */
uint32_t gpufx_format_count(void);
const char *gpufx_format_name(uint32_t index);
/* 1 if format is one of the above or an alias ("yuvj420p" and the like), else 0. */
int gpufx_format_supported(const char *format);

/*
 * Opens a package (.zip file or unpacked directory) and compiles its shaders.
 * Effects opened from the same path with the same backend share the compiled package
 * while any of them is open: the file is read again only after all of them are freed.
 * backend: NULL or "auto", "vulkan", "dx12", "metal", "gl".
 */
GpufxEffect *gpufx_effect_open(const char *path, const char *backend);

/*
 * Opens count packages as one chain: each effect takes the output of the one before it,
 * and a frame is uploaded once, runs through every effect in one GPU submission and is
 * read back once. Only the first effect may take more than one input. The functions
 * below then describe the chain: the inputs of the first effect, the output formats of
 * the last, and the parameters of all of them (see gpufx_effect_param_name()).
 * Between two effects the rules are checked against the first output format of one that
 * the next accepts, as two filters in a row would negotiate it, but frames stay RGBA on
 * the GPU: nothing is converted to that format (no chroma subsampling, alpha kept).
 * Fails when no format the previous effect outputs is accepted by the next.
 */
GpufxEffect *gpufx_effect_open_chain(const char *const *paths, uint32_t count, const char *backend);

/*
 * Since version 5. Opens a graph of effects that runs in one GPU submission:
 *   "[0]split[a][b]; [a]blur.zip[ba]; [b]gray.zip|vignette.zip[gb]; [ba][gb]crossfade.zip[out]"
 * Statements are separated by ';'. Each reads labels, runs a node and writes labels.
 * [0], [1]... are the input pads (named "in0", "in1"...); every pad up to the highest
 * must be read. Other labels (letters, digits, '_', '-') are written once and read at most once (split them to read
 * them twice). Labels no statement reads are the output pads, in the order they are
 * written; gpufx_effect_output_name() gives their labels. A node is:
 *   split         one label in, any number out, no copy (the outputs are the input)
 *   null          one label in, one out, no copy
 *   a.zip|b.zip   packages (paths, as for gpufx_effect_open) chained as in
 *                 gpufx_effect_open_chain(): as many labels in as the first package has
 *                 inputs, one out.
 * An effect writes the size of its first input. Every input is uploaded once and every
 * output read back once; edges stay on the GPU in pooled textures that are reused once
 * their last reader has run. Cycles, labels read but never written, written twice or
 * read twice, unread pads and wrong label counts fail here; the manifest size and format
 * rules of every node are checked by gpufx_effect_check_inputs(). Paths must not contain
 * '[', ']', ';' or '|'.
 * Parameters are named as in a chain over all packages of the graph, in statement order;
 * gpufx_effect_find_param() also takes "label.name" where label is the output label of a
 * node ("ba.radius"). The other functions describe the graph: input formats are those
 * every effect reading the pad accepts, gpufx_effect_output_format*() describe output 0.
 */
GpufxEffect *gpufx_effect_open_graph(const char *graph, const char *backend);
void gpufx_effect_free(GpufxEffect *fx);

/* Strings below are owned by the effect and live as long as it does. */
const char *gpufx_effect_name(const GpufxEffect *fx);
/* Adapter and API in use, e.g. "NVIDIA GeForce RTX 4070 (Vulkan)". */
const char *gpufx_effect_device(const GpufxEffect *fx);

uint32_t gpufx_effect_input_count(const GpufxEffect *fx);
const char *gpufx_effect_input_name(const GpufxEffect *fx, uint32_t index);

/*
 * Pixel formats an input accepts (FFmpeg names). A count of 0 means any format.
 * Formats outside the list are rejected by gpufx_effect_check_inputs().
 */
uint32_t gpufx_effect_input_format_count(const GpufxEffect *fx, uint32_t input);
const char *gpufx_effect_input_format(const GpufxEffect *fx, uint32_t input, uint32_t index);

/* Pixel formats the effect may output, in order of preference (at least one). */
uint32_t gpufx_effect_output_format_count(const GpufxEffect *fx);
const char *gpufx_effect_output_format(const GpufxEffect *fx, uint32_t index);

/*
 * Since version 5. Output pads: 1 for an effect or a chain (named "default"), any number
 * for a graph (named after their labels).
 */
uint32_t gpufx_effect_output_count(const GpufxEffect *fx);
const char *gpufx_effect_output_name(const GpufxEffect *fx, uint32_t output);
/*
 * Since version 5. The input pad whose size output has (effects write the size of their
 * first input), or a negative value when there is no such output.
 */
int gpufx_effect_output_source(const GpufxEffect *fx, uint32_t output);
/* Since version 5. gpufx_effect_output_format*() for any output pad. */
uint32_t gpufx_effect_output_pad_format_count(const GpufxEffect *fx, uint32_t output);
const char *gpufx_effect_output_pad_format(const GpufxEffect *fx, uint32_t output, uint32_t index);

/*
 * Checks one stream per input against the manifest rules (pixel format, size limits,
 * same_size). Returns a negative value and sets gpufx_last_error() on a mismatch.
 */
int gpufx_effect_check_inputs(const GpufxEffect *fx, const GpufxStreamInfo *streams, uint32_t count);

/*
 * Parameters. For one effect the names are those of the manifest. In a chain they are
 * "label.name", where label is the package file name without ".zip", or "index.name"
 * (0 based) when two packages share a label or the label is a number.
 */
uint32_t gpufx_effect_param_count(const GpufxEffect *fx);
const char *gpufx_effect_param_name(const GpufxEffect *fx, uint32_t index);

/*
 * Index of a parameter for gpufx_effect_param_name(). Takes the full name, "label.name",
 * "index.name", or a bare name that only one effect of the chain has. A prefix of
 * digits is always an index. Returns a negative
 * value and sets gpufx_last_error() when no parameter or several match.
 * The functions below take the same names.
 */
int gpufx_effect_find_param(const GpufxEffect *fx, const char *name);

/* Sets a parameter from text: "0.5", "1,0,0", "#ff8800", "true". */
int gpufx_effect_set_param(GpufxEffect *fx, const char *name, const char *value);
/* Sets the first count (1..4) components of a parameter. */
int gpufx_effect_set_param_values(GpufxEffect *fx, const char *name,
                                  const double *values, uint32_t count);

/*
 * Runs the effect. inputs holds one image per input, in order. out must have the size of
 * inputs[0]. Fails when the input sizes break the manifest rules.
 * Same as gpufx_effect_process_frames() with "rgba" frames.
 */
int gpufx_effect_process(GpufxEffect *fx, const GpufxImage *inputs, uint32_t nb_inputs,
                         const GpufxOutput *out, const GpufxFrameInfo *info);

/*
 * Runs the effect on frames of any gpufx_format_name() format: inputs are converted to
 * RGBA (rgba16float, so 10-bit survives) on the GPU, every effect of the chain runs, and
 * the result is converted to out's format and colour properties on the GPU before it is
 * read back. Inputs and out may each have another format. out must have the size of
 * inputs[0]. The planes of out must not overlap each other or any input plane (refused). The manifest format rules are the caller's to check
 * (gpufx_effect_check_inputs()); the frames' formats here are only how they are stored.
 */
int gpufx_effect_process_frames(GpufxEffect *fx, const GpufxFrame *inputs, uint32_t nb_inputs,
                                const GpufxFrameOut *out, const GpufxFrameInfo *info);

/*
 * Since version 5. gpufx_effect_process_frames() for any number of outputs: outs holds
 * one frame per output pad, each the size of its gpufx_effect_output_source() input.
 * Everything runs in one GPU submission and all outputs are read back together through
 * one shared buffer. No plane may overlap another (refused).
 * gpufx_effect_process_frames() and gpufx_effect_convert_frame() refuse a graph with
 * several outputs.
 */
int gpufx_effect_process_graph(GpufxEffect *fx, const GpufxFrame *inputs, uint32_t nb_inputs,
                               const GpufxFrameOut *outs, uint32_t nb_outputs,
                               const GpufxFrameInfo *info);

/*
 * Since version 5. Bypass for any number of outputs: each output is its
 * gpufx_effect_output_source() input converted to its format, without running the effects.
 * inputs may hold only the first pads, as long as every output's source is among them.
 */
int gpufx_effect_convert_graph(GpufxEffect *fx, const GpufxFrame *inputs, uint32_t nb_inputs,
                               const GpufxFrameOut *outs, uint32_t nb_outputs);

/*
 * Converts input to out's format and colour properties without running
 * the effects, as a disabled filter passes its first input through. input stands for
 * the first input; out must have its size.
 */
int gpufx_effect_convert_frame(GpufxEffect *fx, const GpufxFrame *input, const GpufxFrameOut *out);

/*
 * Since version 6: Vulkan frames without copies. The effect runs on a Vulkan device the
 * caller made (FFmpeg's AVVulkanDeviceContext) and reads and writes its VkImages in
 * place. Handles are passed without <vulkan/vulkan.h>: dispatchable handles as
 * pointers, non-dispatchable ones (VkImage, VkSemaphore) as uint64_t.
 */

/* 1 when this library can share a Vulkan device (Linux, Windows), else 0. */
int gpufx_vulkan_supported(void);

typedef struct GpufxVulkanDevice {
    void *get_instance_proc_addr; /* PFN_vkGetInstanceProcAddr of the instance's loader */
    void *instance;               /* VkInstance */
    void *physical_device;        /* VkPhysicalDevice */
    void *device;                 /* VkDevice */
    uint32_t api_version;         /* API version of the instance, at least 1.1 */
    /*
     * The queue gpufx submits to (a family with compute, and the queue in it), and the
     * VkDeviceQueueCreateFlags it was created with. While gpufx_effect_process_vulkan()
     * runs, no other thread may submit to that queue (lock it around the call).
     */
    uint32_t queue_family;
    uint32_t queue_index;
    uint32_t queue_flags;
    /* Extensions enabled on the instance and on the device. */
    uint32_t nb_instance_extensions;
    const char *const *instance_extensions;
    uint32_t nb_device_extensions;
    const char *const *device_extensions;
    /*
     * VkPhysicalDeviceFeatures2 chain of the features enabled on the device: gpufx
     * (wgpu) uses no feature or extension the device was not created with. Only read
     * during gpufx_effect_use_vulkan().
     */
    const void *device_features;
} GpufxVulkanDevice;

/*
 * Moves an open effect (and its parameter values) to the Vulkan device dev: the packages
 * are compiled again for it, unless an effect already uses that device (shared, by
 * VkDevice, like the packages). dev must outlive the effect. Only effects moved this way
 * take gpufx_effect_process_vulkan().
 */
int gpufx_effect_use_vulkan(GpufxEffect *fx, const GpufxVulkanDevice *dev);

/*
 * A frame of Vulkan images, one VkImage per plane of format (FFmpeg: one image per plane,
 * i.e. AVVulkanFramesContext without multiplane images), each of the per-plane formats
 * VK_FORMAT_R8_UNORM, R8G8_UNORM, R8G8B8A8_UNORM or their R16 versions, as FFmpeg uses
 * them. Inputs need SAMPLED usage, outputs STORAGE.
 */
typedef struct GpufxVulkanFrame {
    const char *format;          /* pixel format of the planes (FFmpeg's sw_format name) */
    uint32_t width;
    uint32_t height;
    uint32_t nb_images;          /* one per plane */
    uint64_t image[4];           /* VkImage */
    int32_t vk_format[4];        /* VkFormat of each image */
    int32_t layout[4];           /* in: VkImageLayout; out: the layout it is left in */
    uint64_t semaphore[4];       /* timeline VkSemaphore of each image */
    uint64_t sem_value[4];       /* in: value to wait for; out: value signalled when done */
    uint32_t queue_family[4];    /* owner, or VK_QUEUE_FAMILY_IGNORED (concurrent sharing) */
    GpufxColor color;
} GpufxVulkanFrame;

/*
 * gpufx_effect_process_graph() on Vulkan frames: one submission to the device's queue
 * waits for every image's semaphore at sem_value, runs the conversions and effects
 * reading and writing the images directly (no copy, no readback), and signals each
 * semaphore at sem_value + 1. On return the work is submitted, not finished: layout and
 * sem_value of every image are updated, and the caller stores them in its frames
 * (AVVkFrame) while it still holds them (lock_frame). With info NULL the effects are
 * bypassed as in gpufx_effect_convert_graph().
 */
int gpufx_effect_process_vulkan(GpufxEffect *fx, GpufxVulkanFrame *inputs, uint32_t nb_inputs,
                                GpufxVulkanFrame *outs, uint32_t nb_outputs,
                                const GpufxFrameInfo *info);

#ifdef __cplusplus
}
#endif

#endif /* GPUFX_H */
