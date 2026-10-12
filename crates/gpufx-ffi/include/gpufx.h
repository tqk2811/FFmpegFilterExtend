/*
 * gpufx: run GPU effect packages (zip with manifest.json + WGSL shaders).
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

#define GPUFX_API_VERSION 2

typedef struct GpufxEffect GpufxEffect;

/* An RGBA8 image in CPU memory. stride is bytes per row, >= width * 4. */
typedef struct GpufxImage {
    const uint8_t *data;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
} GpufxImage;

/* Properties of one input stream, checked against the manifest rules. */
typedef struct GpufxStreamInfo {
    const char *format; /* FFmpeg pixel format name ("yuv420p"), or NULL if unknown */
    uint32_t width;
    uint32_t height;
} GpufxStreamInfo;

/* Returns GPUFX_API_VERSION of the loaded library. */
uint32_t gpufx_version(void);

/* Message of the last error on this thread. Never NULL; valid until the next call. */
const char *gpufx_last_error(void);

/*
 * Opens a package (.zip file or unpacked directory) and compiles its shaders.
 * Effects opened from the same path with the same backend share the compiled package
 * while any of them is open: the file is read again only after all of them are freed.
 * backend: NULL or "auto", "vulkan", "dx12", "metal", "gl".
 */
GpufxEffect *gpufx_effect_open(const char *path, const char *backend);
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
 * Checks one stream per input against the manifest rules (pixel format, size limits,
 * same_size). Returns a negative value and sets gpufx_last_error() on a mismatch.
 */
int gpufx_effect_check_inputs(const GpufxEffect *fx, const GpufxStreamInfo *streams, uint32_t count);

uint32_t gpufx_effect_param_count(const GpufxEffect *fx);
const char *gpufx_effect_param_name(const GpufxEffect *fx, uint32_t index);

/* Sets a parameter from text: "0.5", "1,0,0", "#ff8800", "true". */
int gpufx_effect_set_param(GpufxEffect *fx, const char *name, const char *value);
/* Sets the first count (1..4) components of a parameter. */
int gpufx_effect_set_param_values(GpufxEffect *fx, const char *name,
                                  const double *values, uint32_t count);

/*
 * Runs the effect. inputs holds one image per package input, in order. The output
 * has the size of inputs[0] and is written to out with row stride out_stride.
 * time is in seconds, frame is the frame index; both are exposed to shaders.
 * Fails when the input sizes break the manifest rules.
 */
int gpufx_effect_process(GpufxEffect *fx, const GpufxImage *inputs, uint32_t nb_inputs,
                         uint8_t *out, uint32_t out_stride, double time, uint64_t frame);

#ifdef __cplusplus
}
#endif

#endif /* GPUFX_H */
