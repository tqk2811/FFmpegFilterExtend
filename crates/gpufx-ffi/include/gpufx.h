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

#define GPUFX_API_VERSION 3

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
 */
int gpufx_effect_process(GpufxEffect *fx, const GpufxImage *inputs, uint32_t nb_inputs,
                         const GpufxOutput *out, const GpufxFrameInfo *info);

#ifdef __cplusplus
}
#endif

#endif /* GPUFX_H */
