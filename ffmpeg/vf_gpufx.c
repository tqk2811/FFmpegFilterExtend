/*
 * gpufx filter: run a GPU effect package (zip with manifest.json + WGSL shaders)
 * through libgpufx. New effects need no FFmpeg rebuild: pass a different package.
 *
 * The package manifest decides which pixel formats and sizes each input accepts
 * and which formats the output may have. Inputs with a format list take frames
 * as they come and fail on a mismatch instead of being converted silently.
 * libgpufx converts the common YUV formats (NV12, P010, yuv420p...) to and from
 * the RGBA the effects work in on the GPU; other input formats go through swscale.
 * Like the *_cuda filters, gpufx outputs GPU frames only (Vulkan, D3D12, D3D11 or
 * VideoToolbox): put
 * hwdownload or gpufx_download before CPU filters and encoders. Software inputs are
 * uploaded by the filter on the device of its GPU inputs, or on -filter_hw_device.
 * graph='[0]split[a][b]; [a]x.zip[c]; [c][b]y.zip[out]' runs a whole effect graph in
 * one GPU submission, with one input pad per [N] and one output pad per label that no
 * statement reads.
 * Vulkan frames with one image per plane (hwupload on a device opened with
 * disable_multiplane=1) are processed in place on FFmpeg's own Vulkan device, without a
 * trip through RAM: libgpufx shares the device and reads and writes the VkImages,
 * synchronised with their timeline semaphores. Multiplane images, which the Vulkan
 * decoders (-hwaccel vulkan) output, are refused.
 * D3D12 frames (hwupload on -init_hw_device d3d12va) are processed on FFmpeg's own
 * ID3D12Device in the same way, synchronised with their fences. D3D11 frames run on the
 * D3D12 device of the same adapter: the output frames gpufx makes are shared textures
 * (no copy), inputs from elsewhere are copied once on the GPU.
 * VideoToolbox frames (macOS: hwupload on -init_hw_device videotoolbox, or the decoders)
 * are read and written in place through their IOSurfaces on the system's Metal device;
 * without a fence to hand on, each event returns once the GPU is done.
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include <gpufx.h>

#include "config.h"
#include "libavutil/avassert.h"
#include "libavutil/avstring.h"
#include "libavutil/eval.h"
#include "libavutil/imgutils.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"
#include "libswscale/swscale.h"
#include "libavutil/hwcontext.h"
#if CONFIG_VULKAN
#include "libavutil/hwcontext_vulkan.h"
#include "libavutil/internal.h"
#endif
#if CONFIG_D3D12VA
#include "libavutil/hwcontext_d3d12va.h"
#endif
#if CONFIG_D3D11VA
#include "libavutil/hwcontext_d3d11va.h"
#endif

#include "avfilter.h"
#include "filters.h"
#include "formats.h"
#include "framesync.h"
#include "video.h"
#include "vf_gpufx_vk.h"

static const char *const var_names[] = { "t", "n", "w", "h", "a", "sar", "dar", NULL };
enum { VAR_T, VAR_N, VAR_W, VAR_H, VAR_A, VAR_SAR, VAR_DAR, VAR_NB };

/* passthrough option: what a gpufx disabled by timeline enable= hands downstream. */
enum {
    PASSTHROUGH_OFF,  /* always the GPU bypass into the output's own frames */
    PASSTHROUGH_AUTO, /* the input's texture relabelled as an output frame when nothing would change (see passthrough_ok) */
};

typedef struct ParamExpr {
    char *name;
    AVExpr *expr;
} ParamExpr;

/* "<node>.enable=<expr>" in params: an effect of a chain or graph switched per frame. */
typedef struct NodeExpr {
    char *node;   /* the prefix before ".enable", "" for a bare "enable" */
    AVExpr *expr;
    int state;    /* last value given to libgpufx, -1 before the first frame */
} NodeExpr;

typedef struct GpufxContext {
    const AVClass *class;

    char *effect_path;
    char *graph_str;
    char *params_str;
    char *backend;
    int shortest;

    GpufxEffect *fx;
    unsigned nb_inputs;
    unsigned nb_outputs;
    ParamExpr *exprs;
    int nb_exprs;
    NodeExpr *node_exprs;
    int nb_node_exprs;
    AVFrame **conv;  /* per-input copies to upload: swscale conversions or flipped frames */
    SwsContext **in_sws;
    AVFrame **blank;  /* GPU black frame for inputs > 0 before their first frame */
    AVFrame **in;     /* frame of each input in the current event, NULL before it starts */
    /* Per output: */
    AVFrame **out;
    int *source;        /* input pad whose size, rate and aspect ratio the output has */
    int configured;     /* inputs checked and framesync set up (by the first output) */
    FFFrameSync fs;
    int64_t frame_count;
    int warned_interlaced;
    int warned_hdr;
    enum AVPixelFormat out_format; /* forced output format, AV_PIX_FMT_NONE: chosen as before */
    int passthrough;               /* PASSTHROUGH_* */
    int logged_passthrough;        /* 1: relabel logged, 2: GPU copy logged */
    /* GPU frames: every output and GPU input is hw_fmt (Vulkan, D3D12, D3D11 or VideoToolbox). */
    enum AVPixelFormat hw_fmt;
    AVBufferRef *hw_device; /* the device libgpufx runs on, held while it does */
    enum AVPixelFormat *hw_in_fmt; /* sw_format of each input (of its upload frames for software) */
    /* Software inputs, uploaded by the filter itself on the device: */
    AVBufferRef **up_frames; /* frames context of input i, NULL for an input of GPU frames */
    AVBufferRef **up_rgba;   /* RGBA frames for frames the GPU cannot convert, made when needed */
    AVFrame **up_in;         /* the uploaded frame of input i in the current event */
#if CONFIG_VULKAN
    GpufxVulkanFrame *vk_in;
    GpufxVulkanFrame *vk_out;
    uint32_t vk_queue_family;
    /* Frames contexts of the inputs and outputs, held until the effect is freed: libgpufx
     * keeps wrappers of their images from frame to frame. */
    AVBufferRef **vk_frames;
    int nb_vk_frames;
#endif
#if CONFIG_D3D12VA
    GpufxD3D12Frame *d12_in;
    GpufxD3D12Frame *d12_out;
#endif
#if CONFIG_D3D11VA
    GpufxD3D11Frame *d11_in;
    GpufxD3D11Frame *d11_out;
#endif
#if CONFIG_VIDEOTOOLBOX
    GpufxVtFrame *vt_in;
    GpufxVtFrame *vt_out;
#endif
} GpufxContext;

static int gpufx_error(AVFilterContext *ctx, const char *what)
{
    av_log(ctx, AV_LOG_ERROR, "%s: %s\n", what, gpufx_last_error());
    return AVERROR_EXTERNAL;
}

/* Checks the format names of the manifest against what this FFmpeg build can convert. */
static int check_format_name(AVFilterContext *ctx, const char *name, int output)
{
    enum AVPixelFormat fmt = av_get_pix_fmt(name);

    if (fmt == AV_PIX_FMT_NONE) {
        av_log(ctx, AV_LOG_ERROR, "Effect '%s' names unknown pixel format '%s'.\n",
               gpufx_effect_name(((GpufxContext *)ctx->priv)->fx), name);
        return AVERROR(EINVAL);
    }
    if (output ? !sws_isSupportedOutput(fmt) : !sws_isSupportedInput(fmt)) {
        av_log(ctx, AV_LOG_ERROR, "Pixel format '%s' cannot be converted %s RGBA.\n",
               name, output ? "from" : "to");
        return AVERROR(ENOSYS);
    }
    return 0;
}

static void free_expr(ParamExpr *e)
{
    av_freep(&e->name);
    av_expr_free(e->expr);
    e->expr = NULL;
}

static void drop_expr(GpufxContext *s, const char *name)
{
    for (int i = 0; i < s->nb_exprs; i++) {
        if (!strcmp(s->exprs[i].name, name)) {
            free_expr(&s->exprs[i]);
            s->exprs[i] = s->exprs[--s->nb_exprs];
            return;
        }
    }
}

static void free_node_expr(NodeExpr *e)
{
    av_freep(&e->node);
    av_expr_free(e->expr);
    e->expr = NULL;
}

/*
 * "<node>.enable=<expr>": switches the effects node names (package label, index or graph
 * output label, as in "<node>.<param>"; a bare "enable" for a single effect) on while the
 * expression is not 0, evaluated for every frame like parameter expressions. Not the
 * filter's own timeline option enable=, which is outside params. Entries are kept per
 * spelling of the node: "invert.enable" and "0.enable" naming the same effect are two
 * entries, and the one evaluated last for a frame wins.
 */
static int add_node_expr(AVFilterContext *ctx, const char *name, const char *value)
{
    GpufxContext *s = ctx->priv;
    size_t len = strlen(name) - strlen("enable");
    char *node = av_strndup(name, len ? len - 1 : 0);
    AVExpr *expr = NULL;
    NodeExpr *tmp;
    int ret;

    if (!node)
        return AVERROR(ENOMEM);
    if (name[0] == '.') {
        av_log(ctx, AV_LOG_ERROR, "Invalid '%s': missing effect name before .enable.\n", name);
        av_free(node);
        return AVERROR(EINVAL);
    }
    if (gpufx_effect_find_node(s->fx, node) < 0) {
        av_log(ctx, AV_LOG_ERROR, "Effect '%s': %s\n", gpufx_effect_name(s->fx), gpufx_last_error());
        av_free(node);
        return AVERROR(EINVAL);
    }
    if ((ret = av_expr_parse(&expr, value, var_names, NULL, NULL, NULL, NULL, 0, ctx)) < 0) {
        av_log(ctx, AV_LOG_ERROR, "Invalid expression for '%s': '%s'.\n", name, value);
        av_free(node);
        return ret;
    }
    for (int i = 0; i < s->nb_node_exprs; i++) {
        if (!strcmp(s->node_exprs[i].node, node)) {
            free_node_expr(&s->node_exprs[i]);
            s->node_exprs[i] = s->node_exprs[--s->nb_node_exprs];
            break;
        }
    }
    if (!(tmp = av_realloc_array(s->node_exprs, s->nb_node_exprs + 1, sizeof(*s->node_exprs)))) {
        av_expr_free(expr);
        av_free(node);
        return AVERROR(ENOMEM);
    }
    s->node_exprs = tmp;
    s->node_exprs[s->nb_node_exprs++] = (NodeExpr){ node, expr, -1 };
    return 0;
}

/*
 * Parses "name=value|name=value". A value is either a literal the package
 * understands ("0.5", "1,0,0", "#ff8800") or, for scalar parameters, an
 * expression of t, n, w, h, a (w/h), sar and dar evaluated for every frame
 * ("clip((t-2)/1.5,0,1)"). In a chain, names are "package.name", "index.name"
 * or a bare name only one effect has; they are stored by their full name.
 * "<node>.enable" (or a bare "enable") switches effects: see add_node_expr().
 */
static int apply_params(AVFilterContext *ctx, const char *str)
{
    GpufxContext *s = ctx->priv;
    char *dup, *item, *saveptr = NULL;
    int ret = 0;

    if (!str || !*str)
        return 0;
    if (!(dup = av_strdup(str)))
        return AVERROR(ENOMEM);

    for (item = av_strtok(dup, "|", &saveptr); item; item = av_strtok(NULL, "|", &saveptr)) {
        char *value = strchr(item, '='), *dot;
        const char *name;
        AVExpr *expr = NULL;
        ParamExpr *tmp;
        int index;

        if (!value) {
            av_log(ctx, AV_LOG_ERROR, "Expected name=value in params, got '%s'.\n", item);
            ret = AVERROR(EINVAL);
            break;
        }
        *value++ = 0;
        /* No package has a parameter named enable: the name is reserved for this. */
        dot = strrchr(item, '.');
        if (!strcmp(item, "enable") || (dot && !strcmp(dot + 1, "enable"))) {
            if ((ret = add_node_expr(ctx, item, value)) < 0)
                break;
            continue;
        }
        if ((index = gpufx_effect_find_param(s->fx, item)) < 0) {
            av_log(ctx, AV_LOG_ERROR, "Effect '%s': %s\n", gpufx_effect_name(s->fx),
                   gpufx_last_error());
            ret = AVERROR(EINVAL);
            break;
        }
        name = gpufx_effect_param_name(s->fx, index);

        drop_expr(s, name);
        if (gpufx_effect_set_param(s->fx, name, value) == 0)
            continue;

        ret = av_expr_parse(&expr, value, var_names, NULL, NULL, NULL, NULL, 0, ctx);
        if (ret < 0) {
            av_log(ctx, AV_LOG_ERROR, "Invalid value for '%s': %s\n", name, gpufx_last_error());
            break;
        }
        tmp = av_realloc_array(s->exprs, s->nb_exprs + 1, sizeof(*s->exprs));
        if (!tmp) {
            av_expr_free(expr);
            ret = AVERROR(ENOMEM);
            break;
        }
        s->exprs = tmp;
        s->exprs[s->nb_exprs].name = av_strdup(name);
        s->exprs[s->nb_exprs].expr = expr;
        if (!s->exprs[s->nb_exprs].name) {
            av_expr_free(expr);
            ret = AVERROR(ENOMEM);
            break;
        }
        s->nb_exprs++;
    }
    av_free(dup);
    return ret;
}

static int config_output(AVFilterLink *outlink);

/* "a.zip|b.zip" opens a chain: every effect on the GPU in one submission. */
static av_cold int open_effects(AVFilterContext *ctx)
{
    GpufxContext *s = ctx->priv;
    char *dup, *item, *saveptr = NULL;
    const char **paths = NULL;
    unsigned nb_paths = 0;
    int ret = 0;

    if (!(dup = av_strdup(s->effect_path)))
        return AVERROR(ENOMEM);
    for (item = av_strtok(dup, "|", &saveptr); item; item = av_strtok(NULL, "|", &saveptr)) {
        const char **tmp;
        char *end = item + strlen(item);

        /* 'a.zip | b.zip': spaces around the separator are not part of the paths. */
        while (*item == ' ')
            item++;
        while (end > item && end[-1] == ' ')
            *--end = 0;
        if (!*item)
            continue;
        if (!(tmp = av_realloc_array(paths, nb_paths + 1, sizeof(*paths)))) {
            ret = AVERROR(ENOMEM);
            goto end;
        }
        paths = tmp;
        paths[nb_paths++] = item;
    }
    if (!nb_paths) {
        av_log(ctx, AV_LOG_ERROR, "The 'effect' option names no package.\n");
        ret = AVERROR(EINVAL);
        goto end;
    }
    s->fx = gpufx_effect_open_chain(paths, nb_paths, s->backend);
    if (!s->fx)
        ret = gpufx_error(ctx, "Cannot load effect");
end:
    av_free(paths);
    av_free(dup);
    return ret;
}

static av_cold int init(AVFilterContext *ctx)
{
    GpufxContext *s = ctx->priv;
    int ret;

    if (!s->effect_path == !s->graph_str) {
        av_log(ctx, AV_LOG_ERROR, s->effect_path ?
               "Set either 'effect' or 'graph', not both.\n" :
               "The 'effect' option (path to a .zip package) or the 'graph' option is required.\n");
        return AVERROR(EINVAL);
    }
    /*
     * The filter runs on FFmpeg's Vulkan, D3D12 or D3D11 device, or on Metal for VideoToolbox
     * frames: no OpenGL frames.
     */
    if (s->backend && (!av_strcasecmp(s->backend, "gl") ||
                       (!av_strcasecmp(s->backend, "metal") && !gpufx_videotoolbox_supported()))) {
        av_log(ctx, AV_LOG_ERROR, "backend=%s: gpufx runs on the Vulkan, D3D12 or D3D11 device of "
               "its frames or of -filter_hw_device (Metal for VideoToolbox frames on macOS); "
               "use auto, vulkan or dx12.\n", s->backend);
        return AVERROR(EINVAL);
    }
    /* Versions only add functions: a newer library works. */
    if (gpufx_version() < GPUFX_API_VERSION) {
        av_log(ctx, AV_LOG_ERROR, "libgpufx API version %u is older than the headers (%u).\n",
               gpufx_version(), GPUFX_API_VERSION);
        return AVERROR(EINVAL);
    }

    if (s->graph_str) {
        if (!(s->fx = gpufx_effect_open_graph(s->graph_str, s->backend)))
            return gpufx_error(ctx, "Cannot load graph");
    } else if ((ret = open_effects(ctx)) < 0) {
        return ret;
    }
    /* The device is chosen in config_inputs(): FFmpeg's, of the GPU inputs or -filter_hw_device. */
    av_log(ctx, AV_LOG_VERBOSE, "Loaded '%s'\n", gpufx_effect_name(s->fx));

    s->nb_inputs = gpufx_effect_input_count(s->fx);
    for (unsigned i = 0; i < s->nb_inputs; i++) {
        AVFilterPad pad = { 0 };

        pad.type = AVMEDIA_TYPE_VIDEO;
        pad.name = av_strdup(gpufx_effect_input_name(s->fx, i));
        if (!pad.name)
            return AVERROR(ENOMEM);
        if ((ret = ff_append_inpad_free_name(ctx, &pad)) < 0)
            return ret;
    }

    s->nb_outputs = gpufx_effect_output_count(s->fx);
    for (unsigned k = 0; k < s->nb_outputs; k++) {
        AVFilterPad pad = { 0 };

        pad.type         = AVMEDIA_TYPE_VIDEO;
        pad.config_props = config_output;
        pad.name         = av_strdup(gpufx_effect_output_name(s->fx, k));
        if (!pad.name)
            return AVERROR(ENOMEM);
        if ((ret = ff_append_outpad_free_name(ctx, &pad)) < 0)
            return ret;
        /*
         * framesync asserts a single output when it is set up: do it while there is
         * one. activate() makes up for what it only does on the first output.
         */
        if (k == 0 && (ret = ff_framesync_init(&s->fs, ctx, s->nb_inputs)) < 0)
            return ret;
    }

    for (unsigned i = 0; i < s->nb_inputs; i++)
        for (uint32_t j = 0; j < gpufx_effect_input_format_count(s->fx, i); j++)
            if ((ret = check_format_name(ctx, gpufx_effect_input_format(s->fx, i, j), 0)) < 0)
                return ret;
    for (unsigned k = 0; k < s->nb_outputs; k++)
        for (uint32_t j = 0; j < gpufx_effect_output_pad_format_count(s->fx, k); j++)
            if ((ret = check_format_name(ctx, gpufx_effect_output_pad_format(s->fx, k, j), 1)) < 0)
                return ret;
    /* out_format: every output must be allowed to have it, and the GPU must convert it. */
    if (s->out_format != AV_PIX_FMT_NONE) {
        const char *name = av_get_pix_fmt_name(s->out_format);

        if (!gpufx_format_supported(name)) {
            av_log(ctx, AV_LOG_ERROR, "out_format=%s is not converted on the GPU by libgpufx "
                   "(nv12, yuv420p, p010le, rgba...).\n", name);
            return AVERROR(EINVAL);
        }
        for (unsigned k = 0; k < s->nb_outputs; k++) {
            const uint32_t count = gpufx_effect_output_pad_format_count(s->fx, k);
            int listed = 0;

            for (uint32_t j = 0; j < count && !listed; j++)
                listed = !strcmp(gpufx_effect_output_pad_format(s->fx, k, j), name);
            if (!listed) {
                av_log(ctx, AV_LOG_ERROR, "out_format=%s: output '%s' of '%s' cannot have that format.\n",
                       name, gpufx_effect_output_name(s->fx, k), gpufx_effect_name(s->fx));
                return AVERROR(EINVAL);
            }
        }
    }

    s->conv     = av_calloc(s->nb_inputs, sizeof(*s->conv));
    s->in_sws   = av_calloc(s->nb_inputs, sizeof(*s->in_sws));
    s->blank    = av_calloc(s->nb_inputs, sizeof(*s->blank));
    s->in       = av_calloc(s->nb_inputs, sizeof(*s->in));
    s->out      = av_calloc(s->nb_outputs, sizeof(*s->out));
    s->source   = av_calloc(s->nb_outputs, sizeof(*s->source));
    if (!s->conv || !s->in_sws || !s->blank || !s->in || !s->out || !s->source)
        return AVERROR(ENOMEM);
    for (unsigned k = 0; k < s->nb_outputs; k++) {
        s->source[k] = gpufx_effect_output_source(s->fx, k);
        if (s->source[k] < 0 || s->source[k] >= (int)s->nb_inputs) {
            av_log(ctx, AV_LOG_ERROR, "Output %u has no source input: %s\n", k, gpufx_last_error());
            return AVERROR(EINVAL);
        }
    }

    return apply_params(ctx, s->params_str);
}

static av_cold void uninit(AVFilterContext *ctx)
{
    GpufxContext *s = ctx->priv;

    ff_framesync_uninit(&s->fs);
    for (int i = 0; i < s->nb_exprs; i++)
        free_expr(&s->exprs[i]);
    av_freep(&s->exprs);
    for (int i = 0; i < s->nb_node_exprs; i++)
        free_node_expr(&s->node_exprs[i]);
    av_freep(&s->node_exprs);
    for (unsigned i = 0; s->conv && i < s->nb_inputs; i++)
        av_frame_free(&s->conv[i]);
    for (unsigned i = 0; s->in_sws && i < s->nb_inputs; i++)
        sws_free_context(&s->in_sws[i]);
    for (unsigned i = 0; s->blank && i < s->nb_inputs; i++)
        av_frame_free(&s->blank[i]);
    for (unsigned k = 0; s->out && k < s->nb_outputs; k++)
        av_frame_free(&s->out[k]);
    av_freep(&s->blank);
    av_freep(&s->conv);
    av_freep(&s->in_sws);
    av_freep(&s->in);
    av_freep(&s->out);
    av_freep(&s->source);
    av_freep(&s->hw_in_fmt);
    for (unsigned i = 0; s->up_in && i < s->nb_inputs; i++)
        av_frame_free(&s->up_in[i]);
    av_freep(&s->up_in);
#if CONFIG_VULKAN
    av_freep(&s->vk_in);
    av_freep(&s->vk_out);
#endif
#if CONFIG_D3D12VA
    av_freep(&s->d12_in);
    av_freep(&s->d12_out);
#endif
#if CONFIG_D3D11VA
    av_freep(&s->d11_in);
    av_freep(&s->d11_out);
#endif
#if CONFIG_VIDEOTOOLBOX
    av_freep(&s->vt_in);
    av_freep(&s->vt_out);
#endif
    gpufx_effect_free(s->fx);
    s->fx = NULL;
#if CONFIG_VULKAN
    /* After the effect, which may still hold wrappers of their images. */
    for (int i = 0; i < s->nb_vk_frames; i++)
        av_buffer_unref(&s->vk_frames[i]);
    av_freep(&s->vk_frames);
#endif
    for (unsigned i = 0; s->up_frames && i < s->nb_inputs; i++)
        av_buffer_unref(&s->up_frames[i]);
    for (unsigned i = 0; s->up_rgba && i < s->nb_inputs; i++)
        av_buffer_unref(&s->up_rgba[i]);
    av_freep(&s->up_frames);
    av_freep(&s->up_rgba);
    /* After the effect: libgpufx runs on this device until it is freed. */
    av_buffer_unref(&s->hw_device);
}

/* Reuses *frame when it already is a w x h frame of format fmt. */
static int alloc_frame(AVFrame **frame, enum AVPixelFormat fmt, int w, int h)
{
    AVFrame *f = *frame;

    if (f && f->format == fmt && f->width == w && f->height == h)
        return 0;
    av_frame_free(frame);
    if (!(f = av_frame_alloc()))
        return AVERROR(ENOMEM);
    f->format = fmt;
    f->width  = w;
    f->height = h;
    *frame = f;
    return av_frame_get_buffer(f, 0);
}

/*
 * The RGBA side of a conversion: full range RGB with the primaries, transfer and
 * field order of the other side, so swscale only converts the matrix and range and
 * never maps gamut or transfer.
 */
static void set_rgba_props(AVFrame *rgba, const AVFrame *other)
{
    const int field_flags = AV_FRAME_FLAG_INTERLACED | AV_FRAME_FLAG_TOP_FIELD_FIRST;

    rgba->colorspace      = AVCOL_SPC_RGB;
    rgba->color_range     = AVCOL_RANGE_JPEG;
    rgba->color_primaries = other->color_primaries;
    rgba->color_trc       = other->color_trc;
    rgba->chroma_location = AVCHROMA_LOC_UNSPECIFIED;
    rgba->alpha_mode      = AVALPHA_MODE_STRAIGHT;
    rgba->flags           = (rgba->flags & ~field_flags) | (other->flags & field_flags);
}

/*
 * Same size conversion with the frame API: swscale reads the matrix and range of
 * both frames (yuvj and gray included) and sets itself up again when they change.
 */
static int sws_convert(SwsContext **sws, AVFrame *dst, const AVFrame *src)
{
    if (!*sws) {
        if (!(*sws = sws_alloc_context()))
            return AVERROR(ENOMEM);
        (*sws)->flags = SWS_BICUBIC;
    }
    return sws_scale_frame(*sws, dst, src);
}

static int has_alpha(enum AVPixelFormat fmt)
{
    return !!(av_pix_fmt_desc_get(fmt)->flags & AV_PIX_FMT_FLAG_ALPHA);
}

/* RGBA format swscale converts to and from: 16 bits per channel for deep formats. */
static enum AVPixelFormat rgba_for(enum AVPixelFormat fmt)
{
    return av_pix_fmt_desc_get(fmt)->comp[0].depth > 8 ? AV_PIX_FMT_RGBA64LE : AV_PIX_FMT_RGBA;
}

/* GPUFX_MATRIX_* of a colorspace, or -1 when only swscale converts it. */
static int gpu_matrix(enum AVColorSpace cs)
{
    switch (cs) {
    case AVCOL_SPC_BT709:      return GPUFX_MATRIX_BT709;
    case AVCOL_SPC_BT2020_NCL: return GPUFX_MATRIX_BT2020;
    /* Unknown matrices are BT.601 for swscale too. */
    case AVCOL_SPC_UNSPECIFIED:
    case AVCOL_SPC_BT470BG:
    case AVCOL_SPC_SMPTE170M:  return GPUFX_MATRIX_BT601;
    default:                   return -1;
    }
}

static uint32_t gpu_chroma_location(const AVFrame *f, int full_range)
{
    switch (f->chroma_location) {
    case AVCHROMA_LOC_CENTER:     return GPUFX_CHROMA_CENTER;
    case AVCHROMA_LOC_TOPLEFT:    return GPUFX_CHROMA_TOPLEFT;
    case AVCHROMA_LOC_TOP:        return GPUFX_CHROMA_TOP;
    case AVCHROMA_LOC_BOTTOMLEFT: return GPUFX_CHROMA_BOTTOMLEFT;
    case AVCHROMA_LOC_BOTTOM:     return GPUFX_CHROMA_BOTTOM;
    case AVCHROMA_LOC_LEFT:       return GPUFX_CHROMA_LEFT;
    /*
     * Unspecified: centred for full range (JPEG/MJPEG convention), else left (the
     * MPEG-2/H.264 default). swscale makes its own guess on the frames it converts.
     */
    default:                      return full_range ? GPUFX_CHROMA_CENTER : GPUFX_CHROMA_LEFT;
    }
}

/* fmt: the format of the pixels, f->format or the sw_format of a hardware frame. */
static uint32_t alpha_flags_fmt(const AVFrame *f, enum AVPixelFormat fmt)
{
    return f->alpha_mode == AVALPHA_MODE_PREMULTIPLIED && has_alpha(fmt) ?
           GPUFX_FRAME_PREMULTIPLIED : 0;
}

/*
 * Colour properties of f for libgpufx. Returns the format name when the GPU converts
 * f as it is, or NULL when swscale must convert it (other formats or matrices).
 */
static const char *gpu_color_fmt(const AVFrame *f, enum AVPixelFormat fmt, GpufxColor *c)
{
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(fmt);
    int matrix = GPUFX_MATRIX_BT601;

    if (!gpufx_format_supported(desc->name))
        return NULL;
    if (!(desc->flags & AV_PIX_FMT_FLAG_RGB) && (matrix = gpu_matrix(f->colorspace)) < 0)
        return NULL;
    c->matrix          = matrix;
    /* yuvj formats are full range whatever the frame says, as for swscale. */
    c->range           = f->color_range == AVCOL_RANGE_JPEG || !strncmp(desc->name, "yuvj", 4) ?
                         GPUFX_RANGE_FULL : GPUFX_RANGE_LIMITED;
    c->chroma_location = gpu_chroma_location(f, c->range == GPUFX_RANGE_FULL);
    c->flags           = alpha_flags_fmt(f, fmt);
    return desc->name;
}

/* Frames context of input i: its link's for GPU frames, the upload one for software frames. */
static AVBufferRef *input_frames(AVFilterContext *ctx, unsigned i)
{
    GpufxContext *s = ctx->priv;

    if (s->up_frames && s->up_frames[i])
        return s->up_frames[i];
    return ff_filter_link(ctx->inputs[i])->hw_frames_ctx;
}

/* Black frame on the GPU for an input that has not started yet. */
/*
 * Its own small frames context like the input's (same device, format and image
 * properties): a frame taken from the input link's pool for the whole stream could starve
 * a fixed-size pool upstream.
 */
static AVBufferRef *blank_frames_ctx(AVBufferRef *frames)
{
    AVHWFramesContext *src = (AVHWFramesContext *)frames->data;
    AVBufferRef *ref = av_hwframe_ctx_alloc(src->device_ref);
    AVHWFramesContext *fc;

    if (!ref)
        return NULL;
    fc            = (AVHWFramesContext *)ref->data;
    fc->format    = src->format;
    fc->sw_format = src->sw_format;
    fc->width     = src->width;
    fc->height    = src->height;
#if CONFIG_VULKAN
    if (src->format == AV_PIX_FMT_VULKAN) {
        /* Same images as the input's: per-plane layout, usage and tiling. */
        const AVVulkanFramesContext *a = src->hwctx;
        AVVulkanFramesContext *b = fc->hwctx;
        b->tiling    = a->tiling;
        b->usage     = a->usage;
        b->img_flags = a->img_flags;
        b->flags     = a->flags;
        for (int j = 0; j < AV_NUM_DATA_POINTERS && j < FF_ARRAY_ELEMS(a->format); j++)
            b->format[j] = a->format[j];
    }
#endif
#if CONFIG_D3D12VA
    if (src->format == AV_PIX_FMT_D3D12) {
        const AVD3D12VAFramesContext *a = src->hwctx;
        AVD3D12VAFramesContext *b = fc->hwctx;
        b->format         = a->format;
        b->resource_flags = a->resource_flags;
        b->heap_flags     = a->heap_flags;
    }
#endif
#if CONFIG_D3D11VA
    if (src->format == AV_PIX_FMT_D3D11) {
        const AVD3D11VAFramesContext *a = src->hwctx;
        AVD3D11VAFramesContext *b = fc->hwctx;
        b->BindFlags = a->BindFlags;
        b->MiscFlags = a->MiscFlags;
    }
#endif
    if (gpufx_hwframe_ctx_init(ref) < 0)
        av_buffer_unref(&ref);
    return ref;
}

static int hw_blank(AVFilterContext *ctx, unsigned i)
{
    GpufxContext *s = ctx->priv;
    AVFilterLink *link = ctx->inputs[i];
    AVFrame *sw = NULL, *hw = NULL;
    AVBufferRef *frames = NULL;
    ptrdiff_t linesize[4];
    int ret;

    if (!(frames = blank_frames_ctx(input_frames(ctx, i)))) {
        av_log(ctx, AV_LOG_ERROR, "Input '%s': cannot make GPU frames for its blank frame.\n",
               ctx->input_pads[i].name);
        return AVERROR(ENOMEM);
    }
    if (!(sw = av_frame_alloc()) || !(hw = av_frame_alloc())) {
        ret = AVERROR(ENOMEM);
        goto end;
    }
    sw->format = s->hw_in_fmt[i];
    sw->width  = link->w;
    sw->height = link->h;
    if ((ret = av_frame_get_buffer(sw, 0)) < 0)
        goto end;
    for (int p = 0; p < 4; p++)
        linesize[p] = sw->linesize[p];
    if ((ret = av_image_fill_black(sw->data, linesize, sw->format, AVCOL_RANGE_MPEG, sw->width, sw->height)) < 0 ||
        (ret = av_hwframe_get_buffer(frames, hw, 0)) < 0 ||
        (ret = av_hwframe_transfer_data(hw, sw, 0)) < 0)
        goto end;
    av_frame_free(&s->blank[i]);
    s->blank[i] = hw;
    hw = NULL;
end:
    av_frame_free(&sw);
    av_frame_free(&hw);
    av_buffer_unref(&frames);
    return ret;
}

#if CONFIG_VULKAN
/*
 * Vulkan frames. libgpufx runs on FFmpeg's own VkDevice (the device of the inputs'
 * frames contexts) and reads and writes the VkImages of the AVVkFrames in place: one
 * submission waits for each image's timeline semaphore at sem_value and signals
 * sem_value + 1, and leaves every image in VK_IMAGE_LAYOUT_GENERAL.
 */

static int vulkan_ok(void)
{
    return gpufx_vulkan_supported();
}

/* Holds a frames context until the effect is freed (see GpufxContext.vk_frames). */
static int hold_vk_frames(GpufxContext *s, AVBufferRef *frames)
{
    AVBufferRef *ref, **list;

    for (int i = 0; i < s->nb_vk_frames; i++)
        if (s->vk_frames[i]->data == frames->data)
            return 0;
    if (!(list = av_realloc_array(s->vk_frames, s->nb_vk_frames + 1, sizeof(*list))))
        return AVERROR(ENOMEM);
    s->vk_frames = list;
    if (!(ref = av_buffer_ref(frames)))
        return AVERROR(ENOMEM);
    s->vk_frames[s->nb_vk_frames++] = ref;
    return 0;
}

/* Moves the effect to the Vulkan device of the inputs; once, from config_inputs(). */
static int config_vulkan(AVFilterContext *ctx)
{
    GpufxContext *s = ctx->priv;
    AVHWFramesContext *fc0 = NULL;
    AVHWDeviceContext *dev;
    AVVulkanDeviceContext *hwctx;
    GpufxVulkanDevice d = { 0 };
    int family = -1, ret;

    for (unsigned i = 0; i < s->nb_inputs; i++) {
        AVBufferRef *ref = input_frames(ctx, i);
        AVHWFramesContext *fc;

        if (!ref) {
            av_log(ctx, AV_LOG_ERROR, "Input '%s' has Vulkan frames but no frames context.\n",
                   ctx->input_pads[i].name);
            return AVERROR(EINVAL);
        }
        fc = (AVHWFramesContext *)ref->data;
        if (fc0 && fc->device_ref->data != fc0->device_ref->data) {
            av_log(ctx, AV_LOG_ERROR, "Input '%s' comes from another Vulkan device than input '%s'; "
                   "gpufx runs on one device.\n", ctx->input_pads[i].name, ctx->input_pads[0].name);
            return AVERROR(EINVAL);
        }
        fc0 = fc0 ? fc0 : fc;
        s->hw_in_fmt[i] = fc->sw_format;
        /* Before the checks below: their hints (disable_multiplane=1) do not help here. */
        if (gpufx_vk_host_copy_broken(fc)) {
            av_log(ctx, AV_LOG_ERROR, "Input '%s' has Vulkan frames of %s that FFmpeg fills with "
                   "host image copies (hwupload?). " GPUFX_VK_HOST_COPY_HINT "\n",
                   ctx->input_pads[i].name, av_get_pix_fmt_name(fc->sw_format));
            return AVERROR(ENOSYS);
        }
        /* One image per plane: a multiplane image (Vulkan decoders) is not read. */
        if (av_pix_fmt_count_planes(fc->sw_format) > 1 &&
            ((AVVulkanFramesContext *)fc->hwctx)->format[1] == VK_FORMAT_UNDEFINED) {
            av_log(ctx, AV_LOG_ERROR, "Input '%s': multiplane images are not supported; gpufx needs "
                   "one Vulkan image per plane (create the device with disable_multiplane=1; "
                   "decoded frames need hwdownload,hwupload or a copy).\n", ctx->input_pads[i].name);
            return AVERROR(ENOSYS);
        }
        /* FFmpeg makes some formats (yuva420p...) without usage flags: not readable. */
        if (!(((AVVulkanFramesContext *)fc->hwctx)->usage & VK_IMAGE_USAGE_SAMPLED_BIT)) {
            av_log(ctx, AV_LOG_ERROR, "Input '%s' has Vulkan frames of %s that cannot be sampled "
                   "(image usage 0x%x); upload another format.\n", ctx->input_pads[i].name,
                   av_get_pix_fmt_name(fc->sw_format), ((AVVulkanFramesContext *)fc->hwctx)->usage);
            return AVERROR(ENOSYS);
        }
        if (!gpufx_format_supported(av_get_pix_fmt_name(fc->sw_format))) {
            av_log(ctx, AV_LOG_ERROR, "Input '%s' has Vulkan frames of %s, which gpufx does not convert "
                   "on the GPU. Convert before uploading (format=nv12, yuv420p, rgba...).\n",
                   ctx->input_pads[i].name, av_get_pix_fmt_name(fc->sw_format));
            return AVERROR(ENOSYS);
        }
        if ((ret = hold_vk_frames(s, ref)) < 0)
            return ret;
    }
    dev   = (AVHWDeviceContext *)fc0->device_ref->data;
    hwctx = dev->hwctx;
    /* wgpu records render passes and graphics stages, so take FFmpeg's graphics family:
     * the compute one is compute-only on NVIDIA and loses the device. qf[].flags are the
     * roles FFmpeg gave each family, not its capabilities (libgpufx checks those). */
    for (int q = 0; q < hwctx->nb_qf && family < 0; q++)
        if (hwctx->qf[q].flags & VK_QUEUE_GRAPHICS_BIT)
            family = hwctx->qf[q].idx;
    if (family < 0) {
        av_log(ctx, AV_LOG_ERROR, "The Vulkan device has no graphics queue.\n");
        return AVERROR(ENOSYS);
    }
    d.get_instance_proc_addr = (void *)hwctx->get_proc_addr;
    d.instance               = hwctx->inst;
    d.physical_device        = hwctx->phys_dev;
    d.device                 = hwctx->act_dev;
    d.api_version            = VK_API_VERSION_1_3; /* what hwcontext_vulkan asks for */
    d.queue_family           = family;
    d.queue_index            = 0;
    d.queue_flags            = hwctx->queue_flags;
    d.nb_instance_extensions = hwctx->nb_enabled_inst_extensions;
    d.instance_extensions    = hwctx->enabled_inst_extensions;
    d.nb_device_extensions   = hwctx->nb_enabled_dev_extensions;
    d.device_extensions      = hwctx->enabled_dev_extensions;
    d.device_features        = &hwctx->device_features;
    if (gpufx_effect_use_vulkan(s->fx, &d) < 0)
        return gpufx_error(ctx, "Cannot use the Vulkan device");
    if (!(s->hw_device = av_buffer_ref(fc0->device_ref)))
        return AVERROR(ENOMEM);
    s->vk_queue_family = family;
    av_log(ctx, AV_LOG_VERBOSE, "Vulkan frames on %s\n", gpufx_effect_device(s->fx));
    return 0;
}

/*
 * The output frames context is made here by gpufx alone: relabel_hold() relies on nobody
 * else setting its free / user_opaque.
 *
 * The frames context of a Vulkan output: one image per plane (libgpufx writes each plane
 * as its own storage image), in the source input's sw_format when the effect may output
 * it, else the first format of the output that gpufx converts on the GPU.
 */
static int config_vulkan_output(AVFilterLink *outlink, unsigned k)
{
    AVFilterContext *ctx = outlink->src;
    GpufxContext *s = ctx->priv;
    const enum AVPixelFormat want = s->out_format != AV_PIX_FMT_NONE ? s->out_format : s->hw_in_fmt[s->source[k]];
    const uint32_t count = gpufx_effect_output_pad_format_count(s->fx, k);

    /* Pass -1 tries the source input's format, then each format in order. */
    for (int j = -1; j < (int)count; j++) {
        enum AVPixelFormat fmt = j < 0 ? want : av_get_pix_fmt(gpufx_effect_output_pad_format(s->fx, k, j));
        const char *name = av_get_pix_fmt_name(fmt);
        int listed = 0;
        AVBufferRef *ref;
        AVHWFramesContext *fc;
        AVVulkanFramesContext *vk;

        for (uint32_t m = 0; m < count && !listed; m++)
            listed = !strcmp(gpufx_effect_output_pad_format(s->fx, k, m), name);
        if (j >= 0 && s->out_format != AV_PIX_FMT_NONE)
            break; /* out_format: that format or nothing */
        if (!listed || (j >= 0 && fmt == want) || !gpufx_format_supported(name) || !av_vkfmt_from_pixfmt(fmt))
            continue;
        if (!(ref = av_hwframe_ctx_alloc(s->hw_device)))
            return AVERROR(ENOMEM);
        fc            = (AVHWFramesContext *)ref->data;
        fc->format    = AV_PIX_FMT_VULKAN;
        fc->sw_format = fmt;
        fc->width     = outlink->w;
        fc->height    = outlink->h;
        vk            = fc->hwctx;
        vk->flags     = AV_VK_FRAME_FLAG_DISABLE_MULTIPLANE;
        /* Storage usage (libgpufx writes the planes) comes by default where the format has it. */
        if (gpufx_hwframe_ctx_init(ref) < 0 || !(vk->usage & VK_IMAGE_USAGE_STORAGE_BIT)) {
            av_log(ctx, AV_LOG_VERBOSE, "No storage Vulkan frames of %s for output '%s'.\n",
                   name, ctx->output_pads[k].name);
            av_buffer_unref(&ref);
            continue;
        }
        av_buffer_unref(&ff_filter_link(outlink)->hw_frames_ctx);
        ff_filter_link(outlink)->hw_frames_ctx = ref;
        return hold_vk_frames(s, ref);
    }
    if (s->out_format != AV_PIX_FMT_NONE) {
        av_log(ctx, AV_LOG_ERROR, "Output '%s': out_format=%s cannot be written into Vulkan frames "
               "(FFmpeg makes no storage images of it).\n", ctx->output_pads[k].name,
               av_get_pix_fmt_name(s->out_format));
        return AVERROR(ENOSYS);
    }
    av_log(ctx, AV_LOG_ERROR, "Output '%s': no format the effect outputs can be written into Vulkan "
           "frames on the GPU.\n", ctx->output_pads[k].name);
    return AVERROR(ENOSYS);
}

static int vk_fill(AVFilterContext *ctx, const AVFrame *f, GpufxVulkanFrame *v, const char *what)
{
    AVHWFramesContext *fc = (AVHWFramesContext *)f->hw_frames_ctx->data;
    AVVulkanFramesContext *vkfc = fc->hwctx;
    AVVkFrame *vkf = (AVVkFrame *)f->data[0];
    const char *name = gpu_color_fmt(f, fc->sw_format, &v->color);

    if (!name) {
        av_log(ctx, AV_LOG_ERROR, "%s: Vulkan frames of %s in colorspace %s are not converted on the "
               "GPU; set a supported matrix (BT.601, BT.709, BT.2020) before uploading.\n", what,
               av_get_pix_fmt_name(fc->sw_format), av_color_space_name(f->colorspace));
        return AVERROR(ENOSYS);
    }
    v->format    = name;
    v->width     = f->width;
    v->height    = f->height;
    v->nb_images = 0;
    for (int j = 0; j < 4 && vkf->img[j]; j++) {
        v->image[j]        = (uint64_t)vkf->img[j];
        v->vk_format[j]    = vkfc->format[j];
        v->layout[j]       = vkf->layout[j];
        v->semaphore[j]    = (uint64_t)vkf->sem[j];
        v->sem_value[j]    = vkf->sem_value[j];
        v->queue_family[j] = vkf->queue_family[j];
        v->nb_images++;
    }
    return 0;
}

static void vk_store(const AVFrame *f, const GpufxVulkanFrame *v)
{
    AVVkFrame *vkf = (AVVkFrame *)f->data[0];

    for (uint32_t j = 0; j < v->nb_images; j++) {
        vkf->layout[j]    = v->layout[j];
        vkf->sem_value[j] = v->sem_value[j];
        vkf->access[j]    = VK_ACCESS_2_SHADER_READ_BIT | VK_ACCESS_2_SHADER_WRITE_BIT;
    }
}

/*
 * One event on Vulkan frames: the inputs (s->in, or the blank frame of an input that
 * has not started) and s->out are locked, described to libgpufx, processed in one
 * submission and updated with the semaphore values and layouts it leaves. info NULL:
 * bypass (disabled filter).
 */
static int process_vulkan(AVFilterContext *ctx, const GpufxFrameInfo *info)
{
    GpufxContext *s = ctx->priv;
    AVHWDeviceContext *dev = (AVHWDeviceContext *)s->hw_device->data;
    AVVulkanDeviceContext *hwctx = dev->hwctx;
    const unsigned total = s->nb_inputs + s->nb_outputs;
    const AVFrame **frames = av_calloc(total, sizeof(*frames));
    const AVFrame **locked = av_calloc(total, sizeof(*locked));
    unsigned nb_locked = 0;
    int ret = 0;

    if (!frames || !locked) {
        ret = AVERROR(ENOMEM);
        goto end;
    }
    for (unsigned i = 0; i < s->nb_inputs; i++)
        frames[i] = s->in[i] ? s->in[i] : s->blank[i];
    for (unsigned k = 0; k < s->nb_outputs; k++)
        frames[s->nb_inputs + k] = s->out[k];
    /* Each AVVkFrame once: an input split upstream may come on two pads. */
    for (unsigned n = 0; n < total; n++) {
        int seen = 0;
        for (unsigned m = 0; m < nb_locked; m++)
            seen |= locked[m]->data[0] == frames[n]->data[0];
        if (!seen) {
            AVHWFramesContext *fc = (AVHWFramesContext *)frames[n]->hw_frames_ctx->data;
            AVVulkanFramesContext *vkfc = fc->hwctx;
            vkfc->lock_frame(fc, (AVVkFrame *)frames[n]->data[0]);
            locked[nb_locked++] = frames[n];
        }
    }
    for (unsigned i = 0; i < s->nb_inputs && ret >= 0; i++)
        ret = vk_fill(ctx, frames[i], &s->vk_in[i], ctx->input_pads[i].name);
    for (unsigned k = 0; k < s->nb_outputs && ret >= 0; k++)
        ret = vk_fill(ctx, frames[s->nb_inputs + k], &s->vk_out[k], ctx->output_pads[k].name);
    if (ret >= 0) {
#if FF_API_VULKAN_SYNC_QUEUES
FF_DISABLE_DEPRECATION_WARNINGS
        hwctx->lock_queue(dev, s->vk_queue_family, 0);
FF_ENABLE_DEPRECATION_WARNINGS
#endif
        ret = gpufx_effect_process_vulkan(s->fx, s->vk_in, s->nb_inputs, s->vk_out, s->nb_outputs, info);
#if FF_API_VULKAN_SYNC_QUEUES
FF_DISABLE_DEPRECATION_WARNINGS
        hwctx->unlock_queue(dev, s->vk_queue_family, 0);
FF_ENABLE_DEPRECATION_WARNINGS
#endif
        if (ret < 0) {
            ret = gpufx_error(ctx, info ? "Processing failed" : "Conversion failed");
        } else {
            for (unsigned i = 0; i < s->nb_inputs; i++)
                vk_store(frames[i], &s->vk_in[i]);
            for (unsigned k = 0; k < s->nb_outputs; k++)
                vk_store(frames[s->nb_inputs + k], &s->vk_out[k]);
        }
    }
    for (unsigned m = 0; m < nb_locked; m++) {
        AVHWFramesContext *fc = (AVHWFramesContext *)locked[m]->hw_frames_ctx->data;
        AVVulkanFramesContext *vkfc = fc->hwctx;
        vkfc->unlock_frame(fc, (AVVkFrame *)locked[m]->data[0]);
    }
end:
    av_free(frames);
    av_free(locked);
    return ret;
}
#else
static int vulkan_ok(void)
{
    return 0;
}
#endif

/*
 * The GPU frame APIs gpufx runs on: the pixel format of their frames and the FFmpeg device
 * type that makes them. Another API is one more entry here, plus its cases in hw_ok(),
 * config_api(), config_api_output(), sw_format_ok(), upload_ok() and process_hw().
 */
static const struct {
    enum AVPixelFormat fmt;
    enum AVHWDeviceType type;
    const char *name;
} hw_apis[] = {
    { AV_PIX_FMT_VULKAN,       AV_HWDEVICE_TYPE_VULKAN,       "Vulkan"       },
    { AV_PIX_FMT_D3D12,        AV_HWDEVICE_TYPE_D3D12VA,      "D3D12"        },
    { AV_PIX_FMT_D3D11,        AV_HWDEVICE_TYPE_D3D11VA,      "D3D11"        },
    { AV_PIX_FMT_VIDEOTOOLBOX, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, "VideoToolbox" },
};

/*
 * Whether gpufx reads and writes D3D12/D3D11/VideoToolbox frames of sw_format fmt in place,
 * and the list of those formats, in messages.
 */
static int sw_format_ok(enum AVPixelFormat hw_fmt, enum AVPixelFormat fmt)
{
    if (!gpufx_format_supported(av_get_pix_fmt_name(fmt)))
        return 0;
    if (hw_fmt == AV_PIX_FMT_VIDEOTOOLBOX)
        return fmt == AV_PIX_FMT_NV12 || fmt == AV_PIX_FMT_P010;
    return fmt == AV_PIX_FMT_NV12 || fmt == AV_PIX_FMT_P010 || fmt == AV_PIX_FMT_RGBA || fmt == AV_PIX_FMT_RGBA64;
}

static const char *sw_format_list(enum AVPixelFormat hw_fmt)
{
    return hw_fmt == AV_PIX_FMT_VIDEOTOOLBOX ? "nv12, p010le" : "nv12, p010le, rgba, rgba64le";
}

/* Name of the API of GPU frames of format fmt, in messages. */
static const char *api_name(enum AVPixelFormat fmt)
{
    for (int j = 0; j < FF_ARRAY_ELEMS(hw_apis); j++)
        if (hw_apis[j].fmt == fmt)
            return hw_apis[j].name;
    return av_get_pix_fmt_name(fmt);
}

/* Pixel format of the GPU frames a device of this type makes, AV_PIX_FMT_NONE if none we use. */
static enum AVPixelFormat device_hw_format(enum AVHWDeviceType type)
{
    for (int j = 0; j < FF_ARRAY_ELEMS(hw_apis); j++)
        if (hw_apis[j].type == type)
            return hw_apis[j].fmt;
    return AV_PIX_FMT_NONE;
}

/* Checks the frames contexts of the inputs of D3D12/D3D11/VideoToolbox frames; returns the device. */
static AVHWDeviceContext *d3d_inputs(AVFilterContext *ctx, AVBufferRef **device_ref)
{
    GpufxContext *s = ctx->priv;
    AVHWFramesContext *fc0 = NULL;
    const char *api = api_name(s->hw_fmt);

    for (unsigned i = 0; i < s->nb_inputs; i++) {
        AVBufferRef *ref = input_frames(ctx, i);
        AVHWFramesContext *fc;

        if (!ref) {
            av_log(ctx, AV_LOG_ERROR, "Input '%s' has %s frames but no frames context.\n",
                   ctx->input_pads[i].name, api);
            return NULL;
        }
        fc = (AVHWFramesContext *)ref->data;
        if (fc0 && fc->device_ref->data != fc0->device_ref->data) {
            av_log(ctx, AV_LOG_ERROR, "Input '%s' comes from another %s device than input '%s'; "
                   "gpufx runs on one device.\n", ctx->input_pads[i].name, api, ctx->input_pads[0].name);
            return NULL;
        }
        fc0 = fc0 ? fc0 : fc;
        s->hw_in_fmt[i] = fc->sw_format;
        if (!sw_format_ok(s->hw_fmt, fc->sw_format)) {
            av_log(ctx, AV_LOG_ERROR, "Input '%s' has %s frames of %s; gpufx reads %s frames of "
                   "%s. Convert before uploading (format=nv12).\n", ctx->input_pads[i].name, api,
                   av_get_pix_fmt_name(fc->sw_format), api, sw_format_list(s->hw_fmt));
            return NULL;
        }
    }
    *device_ref = fc0->device_ref;
    return (AVHWDeviceContext *)fc0->device_ref->data;
}

/*
 * Moves the effect to the D3D12 or D3D11 device of the inputs, or to Metal for VideoToolbox
 * frames; once, from config_inputs().
 */
static int config_d3d(AVFilterContext *ctx)
{
    GpufxContext *s = ctx->priv;
    AVBufferRef *ref = NULL;
    AVHWDeviceContext *dev = d3d_inputs(ctx, &ref);
    int ret = AVERROR(ENOSYS);

    if (!dev)
        return AVERROR(EINVAL);
#if CONFIG_D3D12VA
    if (s->hw_fmt == AV_PIX_FMT_D3D12) {
        AVD3D12VADeviceContext *hwctx = dev->hwctx;
        GpufxD3D12Device d = { hwctx->device };

        if (gpufx_effect_use_d3d12(s->fx, &d) < 0)
            return gpufx_error(ctx, "Cannot use the D3D12 device");
        ret = 0;
    }
#endif
#if CONFIG_D3D11VA
    if (s->hw_fmt == AV_PIX_FMT_D3D11) {
        AVD3D11VADeviceContext *hwctx = dev->hwctx;
        GpufxD3D11Device d = { hwctx->device, hwctx->device_context };

        if (gpufx_effect_use_d3d11(s->fx, &d) < 0)
            return gpufx_error(ctx, "Cannot use the D3D11 device");
        ret = 0;
    }
#endif
#if CONFIG_VIDEOTOOLBOX
    /* The frames are IOSurfaces any Metal device opens: libgpufx uses the system's. */
    if (s->hw_fmt == AV_PIX_FMT_VIDEOTOOLBOX) {
        if (gpufx_effect_use_videotoolbox(s->fx) < 0)
            return gpufx_error(ctx, "Cannot use Metal for VideoToolbox frames");
        ret = 0;
    }
#endif
    if (ret < 0)
        return ret;
    if (!(s->hw_device = av_buffer_ref(ref)))
        return AVERROR(ENOMEM);
    av_log(ctx, AV_LOG_VERBOSE, "%s frames on %s\n", api_name(s->hw_fmt), gpufx_effect_device(s->fx));
    return 0;
}

/*
 * The frames context of a D3D12/D3D11/VideoToolbox output, in the source input's sw_format when the
 * effect may output it, else the first format of the output gpufx writes into such
 * frames. Frames libgpufx writes as storage (D3D12 unordered access; D3D11 shared NT
 * handle textures with unordered access) if the device makes them, else frames it copies
 * its result into on the GPU.
 */
static int config_d3d_output(AVFilterLink *outlink, unsigned k)
{
    AVFilterContext *ctx = outlink->src;
    GpufxContext *s = ctx->priv;
    const enum AVPixelFormat want = s->out_format != AV_PIX_FMT_NONE ? s->out_format : s->hw_in_fmt[s->source[k]];
    const uint32_t count = gpufx_effect_output_pad_format_count(s->fx, k);

    /* gpufx makes the output frames context alone: relabel_hold() relies on nobody else
     * setting its free / user_opaque. */
    for (int j = -1; j < (int)count; j++) {
        enum AVPixelFormat fmt = j < 0 ? want : av_get_pix_fmt(gpufx_effect_output_pad_format(s->fx, k, j));
        const char *name = av_get_pix_fmt_name(fmt);
        int listed = 0;

        for (uint32_t m = 0; m < count && !listed; m++)
            listed = !strcmp(gpufx_effect_output_pad_format(s->fx, k, m), name);
        if (j >= 0 && s->out_format != AV_PIX_FMT_NONE)
            break; /* out_format: that format or nothing */
        if (!listed || (j >= 0 && fmt == want) || !sw_format_ok(s->hw_fmt, fmt))
            continue;
        /* Storage first; then frames written by a copy (VideoToolbox: one kind of frames). */
        for (int uav = 1; uav >= (s->hw_fmt == AV_PIX_FMT_VIDEOTOOLBOX); uav--) {
            AVBufferRef *ref = av_hwframe_ctx_alloc(s->hw_device);
            AVHWFramesContext *fc;

            if (!ref)
                return AVERROR(ENOMEM);
            fc            = (AVHWFramesContext *)ref->data;
            fc->format    = s->hw_fmt;
            fc->sw_format = fmt;
            fc->width     = outlink->w;
            fc->height    = outlink->h;
#if CONFIG_D3D12VA
            if (s->hw_fmt == AV_PIX_FMT_D3D12 && uav)
                ((AVD3D12VAFramesContext *)fc->hwctx)->resource_flags |= D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
#endif
#if CONFIG_D3D11VA
            if (s->hw_fmt == AV_PIX_FMT_D3D11) {
                AVD3D11VAFramesContext *h = fc->hwctx;
                h->BindFlags = D3D11_BIND_SHADER_RESOURCE | (uav ? D3D11_BIND_UNORDERED_ACCESS : 0);
                h->MiscFlags = D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
            }
#endif
            /* Some devices accept the context but fail to create its textures: try one. */
            if (gpufx_hwframe_ctx_init(ref) >= 0) {
                AVFrame *probe = av_frame_alloc();
                int got;

                if (!probe) {
                    av_buffer_unref(&ref);
                    return AVERROR(ENOMEM);
                }
                got = av_hwframe_get_buffer(ref, probe, 0);
                av_frame_free(&probe);
                if (got < 0)
                    av_buffer_unref(&ref);
            } else {
                av_buffer_unref(&ref);
            }
            if (!ref) {
                av_log(ctx, AV_LOG_VERBOSE, "No %s%s frames of %s for output '%s'.\n",
                       uav ? "storage " : "", api_name(s->hw_fmt), name, ctx->output_pads[k].name);
                continue;
            }
            if (!uav)
                av_log(ctx, AV_LOG_VERBOSE, "Output '%s': the device makes no storage %s frames of %s; "
                       "the result is copied into them on the GPU.\n", ctx->output_pads[k].name,
                       api_name(s->hw_fmt), name);
            av_buffer_unref(&ff_filter_link(outlink)->hw_frames_ctx);
            ff_filter_link(outlink)->hw_frames_ctx = ref;
            return 0;
        }
    }
    if (s->out_format != AV_PIX_FMT_NONE) {
        av_log(ctx, AV_LOG_ERROR, "Output '%s': out_format=%s cannot be written into %s frames "
               "(%s).\n", ctx->output_pads[k].name,
               av_get_pix_fmt_name(s->out_format), api_name(s->hw_fmt), sw_format_list(s->hw_fmt));
        return AVERROR(ENOSYS);
    }
    av_log(ctx, AV_LOG_ERROR, "Output '%s': no format the effect outputs can be written into %s "
           "frames on the GPU (%s).\n", ctx->output_pads[k].name,
           api_name(s->hw_fmt), sw_format_list(s->hw_fmt));
    return AVERROR(ENOSYS);
}

#if CONFIG_D3D12VA || CONFIG_D3D11VA || CONFIG_VIDEOTOOLBOX
/* The frames of one event: inputs (or the blank frame of one not started yet), outputs. */
static const AVFrame *event_frame(GpufxContext *s, unsigned n)
{
    if (n < s->nb_inputs)
        return s->in[n] ? s->in[n] : s->blank[n];
    return s->out[n - s->nb_inputs];
}

static const char *d3d_color(AVFilterContext *ctx, const AVFrame *f, GpufxColor *c, const char *what)
{
    AVHWFramesContext *fc = (AVHWFramesContext *)f->hw_frames_ctx->data;
    const char *name = gpu_color_fmt(f, fc->sw_format, c);

    if (!name)
        av_log(ctx, AV_LOG_ERROR, "%s: frames of %s in colorspace %s are not converted on the "
               "GPU; set a supported matrix (BT.601, BT.709, BT.2020) before uploading.\n", what,
               av_get_pix_fmt_name(fc->sw_format), av_color_space_name(f->colorspace));
    return name;
}
#endif

#if CONFIG_D3D12VA
/*
 * One event on D3D12 frames: libgpufx waits for each frame's fence at its value in one
 * submission, signals one more, and the new values are stored in the frames.
 */
static int process_d3d12(AVFilterContext *ctx, const GpufxFrameInfo *info)
{
    GpufxContext *s = ctx->priv;
    const unsigned total = s->nb_inputs + s->nb_outputs;

    for (unsigned n = 0; n < total; n++) {
        const AVFrame *f = event_frame(s, n);
        AVD3D12VAFrame *d = (AVD3D12VAFrame *)f->data[0];
        GpufxD3D12Frame *g = n < s->nb_inputs ? &s->d12_in[n] : &s->d12_out[n - s->nb_inputs];
        const char *what = n < s->nb_inputs ? ctx->input_pads[n].name : ctx->output_pads[n - s->nb_inputs].name;

        if (!(g->format = d3d_color(ctx, f, &g->color, what)))
            return AVERROR(ENOSYS);
        g->width       = f->width;
        g->height      = f->height;
        g->resource    = d->texture;
        g->subresource = d->subresource_index;
        g->fence       = d->sync_ctx.fence;
        g->fence_value = d->sync_ctx.fence_value;
    }
    if (gpufx_effect_process_d3d12(s->fx, s->d12_in, s->nb_inputs, s->d12_out, s->nb_outputs, info) < 0)
        return gpufx_error(ctx, info ? "Processing failed" : "Conversion failed");
    for (unsigned n = 0; n < total; n++) {
        AVD3D12VAFrame *d = (AVD3D12VAFrame *)event_frame(s, n)->data[0];
        const GpufxD3D12Frame *g = n < s->nb_inputs ? &s->d12_in[n] : &s->d12_out[n - s->nb_inputs];

        d->sync_ctx.fence_value = FFMAX(d->sync_ctx.fence_value, g->fence_value);
    }
    return 0;
}
#endif

#if CONFIG_D3D11VA
/* One event on D3D11 frames, under the device lock (libgpufx uses the immediate context). */
static int process_d3d11(AVFilterContext *ctx, const GpufxFrameInfo *info)
{
    GpufxContext *s = ctx->priv;
    AVD3D11VADeviceContext *hwctx = ((AVHWDeviceContext *)s->hw_device->data)->hwctx;
    const unsigned total = s->nb_inputs + s->nb_outputs;
    int ret;

    for (unsigned n = 0; n < total; n++) {
        const AVFrame *f = event_frame(s, n);
        GpufxD3D11Frame *g = n < s->nb_inputs ? &s->d11_in[n] : &s->d11_out[n - s->nb_inputs];
        const char *what = n < s->nb_inputs ? ctx->input_pads[n].name : ctx->output_pads[n - s->nb_inputs].name;

        if (!(g->format = d3d_color(ctx, f, &g->color, what)))
            return AVERROR(ENOSYS);
        g->width       = f->width;
        g->height      = f->height;
        g->texture     = f->data[0];
        g->array_slice = (uint32_t)(intptr_t)f->data[1];
    }
    hwctx->lock(hwctx->lock_ctx);
    ret = gpufx_effect_process_d3d11(s->fx, s->d11_in, s->nb_inputs, s->d11_out, s->nb_outputs, info);
    hwctx->unlock(hwctx->lock_ctx);
    return ret < 0 ? gpufx_error(ctx, info ? "Processing failed" : "Conversion failed") : 0;
}
#endif

#if CONFIG_VIDEOTOOLBOX
/*
 * One event on VideoToolbox frames (CVPixelBufferRef in data[3]). There is no fence:
 * libgpufx returns once the GPU is done with the IOSurfaces.
 */
static int process_videotoolbox(AVFilterContext *ctx, const GpufxFrameInfo *info)
{
    GpufxContext *s = ctx->priv;
    const unsigned total = s->nb_inputs + s->nb_outputs;

    for (unsigned n = 0; n < total; n++) {
        const AVFrame *f = event_frame(s, n);
        GpufxVtFrame *g = n < s->nb_inputs ? &s->vt_in[n] : &s->vt_out[n - s->nb_inputs];
        const char *what = n < s->nb_inputs ? ctx->input_pads[n].name : ctx->output_pads[n - s->nb_inputs].name;

        if (!(g->format = d3d_color(ctx, f, &g->color, what)))
            return AVERROR(ENOSYS);
        g->width        = f->width;
        g->height       = f->height;
        g->pixel_buffer = f->data[3];
    }
    if (gpufx_effect_process_videotoolbox(s->fx, s->vt_in, s->nb_inputs, s->vt_out, s->nb_outputs, info) < 0)
        return gpufx_error(ctx, info ? "Processing failed" : "Conversion failed");
    return 0;
}
#endif

/* Whether frames of the GPU pixel format fmt are processed in place. */
static int hw_ok(enum AVPixelFormat fmt)
{
    switch (fmt) {
    case AV_PIX_FMT_VULKAN: return vulkan_ok();
#if CONFIG_D3D12VA
    case AV_PIX_FMT_D3D12:  return gpufx_d3d12_supported();
#endif
#if CONFIG_D3D11VA
    case AV_PIX_FMT_D3D11:  return gpufx_d3d12_supported();
#endif
#if CONFIG_VIDEOTOOLBOX
    case AV_PIX_FMT_VIDEOTOOLBOX: return gpufx_videotoolbox_supported();
#endif
    default:                return 0;
    }
}

static int add_hw_formats(AVFilterFormats **formats)
{
    int ret = 0;

    for (int j = 0; j < FF_ARRAY_ELEMS(hw_apis) && ret >= 0; j++)
        if (hw_ok(hw_apis[j].fmt))
            ret = ff_add_format(formats, hw_apis[j].fmt);
    return ret;
}

/* Moves the effect to the device of the inputs (GPU or upload frames); once. */
static int config_api(AVFilterContext *ctx)
{
    GpufxContext *s = ctx->priv;

    switch (s->hw_fmt) {
#if CONFIG_VULKAN
    case AV_PIX_FMT_VULKAN:
        s->vk_in  = av_calloc(s->nb_inputs, sizeof(*s->vk_in));
        s->vk_out = av_calloc(s->nb_outputs, sizeof(*s->vk_out));
        if (!s->vk_in || !s->vk_out)
            return AVERROR(ENOMEM);
        return config_vulkan(ctx);
#endif
#if CONFIG_D3D12VA
    case AV_PIX_FMT_D3D12:
        s->d12_in  = av_calloc(s->nb_inputs, sizeof(*s->d12_in));
        s->d12_out = av_calloc(s->nb_outputs, sizeof(*s->d12_out));
        if (!s->d12_in || !s->d12_out)
            return AVERROR(ENOMEM);
        return config_d3d(ctx);
#endif
#if CONFIG_D3D11VA
    case AV_PIX_FMT_D3D11:
        s->d11_in  = av_calloc(s->nb_inputs, sizeof(*s->d11_in));
        s->d11_out = av_calloc(s->nb_outputs, sizeof(*s->d11_out));
        if (!s->d11_in || !s->d11_out)
            return AVERROR(ENOMEM);
        return config_d3d(ctx);
#endif
#if CONFIG_VIDEOTOOLBOX
    case AV_PIX_FMT_VIDEOTOOLBOX:
        s->vt_in  = av_calloc(s->nb_inputs, sizeof(*s->vt_in));
        s->vt_out = av_calloc(s->nb_outputs, sizeof(*s->vt_out));
        if (!s->vt_in || !s->vt_out)
            return AVERROR(ENOMEM);
        return config_d3d(ctx);
#endif
    default:
        return AVERROR_BUG;
    }
}

/* Frames context of output k on the device. */
static int config_api_output(AVFilterLink *outlink, unsigned k)
{
    GpufxContext *s = outlink->src->priv;

    switch (s->hw_fmt) {
#if CONFIG_VULKAN
    case AV_PIX_FMT_VULKAN: return config_vulkan_output(outlink, k);
#endif
    case AV_PIX_FMT_D3D12:
    case AV_PIX_FMT_D3D11:
    case AV_PIX_FMT_VIDEOTOOLBOX: return config_d3d_output(outlink, k);
    default:                return AVERROR_BUG;
    }
}

/* Whether input frames of sw format fmt can be uploaded as they are to frames of hw_fmt. */
static int upload_ok(enum AVPixelFormat hw_fmt, enum AVPixelFormat fmt)
{
    if (!gpufx_format_supported(av_get_pix_fmt_name(fmt)))
        return 0;
    switch (hw_fmt) {
#if CONFIG_VULKAN
    case AV_PIX_FMT_VULKAN: return !!av_vkfmt_from_pixfmt(fmt);
#endif
    case AV_PIX_FMT_D3D12:
    case AV_PIX_FMT_D3D11:
    case AV_PIX_FMT_VIDEOTOOLBOX: return sw_format_ok(hw_fmt, fmt);
    default:                return 0;
    }
}

/* A frames context of sw_format fmt for uploads on the device, or NULL. */
static AVBufferRef *upload_frames_ctx(AVFilterContext *ctx, AVBufferRef *device, enum AVPixelFormat fmt,
                                      int w, int h)
{
    GpufxContext *s = ctx->priv;
    AVBufferRef *ref;
    AVHWFramesContext *fc;

    if (!upload_ok(s->hw_fmt, fmt) || !(ref = av_hwframe_ctx_alloc(device)))
        return NULL;
    fc            = (AVHWFramesContext *)ref->data;
    fc->format    = s->hw_fmt;
    fc->sw_format = fmt;
    fc->width     = w;
    fc->height    = h;
#if CONFIG_VULKAN
    /* One image per plane, which gpufx reads, whatever the device was opened with. */
    if (s->hw_fmt == AV_PIX_FMT_VULKAN)
        ((AVVulkanFramesContext *)fc->hwctx)->flags = AV_VK_FRAME_FLAG_DISABLE_MULTIPLANE;
#endif
#if CONFIG_D3D11VA
    /* Readable and shareable like the filter's own D3D11 frames, so gpufx needs no copy. */
    if (s->hw_fmt == AV_PIX_FMT_D3D11) {
        AVD3D11VAFramesContext *h = fc->hwctx;
        h->BindFlags = D3D11_BIND_SHADER_RESOURCE;
        h->MiscFlags = D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
    }
#endif
    if (gpufx_hwframe_ctx_init(ref) < 0) {
        av_buffer_unref(&ref);
        return NULL;
    }
#if CONFIG_VULKAN
    /* FFmpeg makes some formats without the usage flags gpufx needs to read them. */
    if (s->hw_fmt == AV_PIX_FMT_VULKAN &&
        !(((AVVulkanFramesContext *)fc->hwctx)->usage & VK_IMAGE_USAGE_SAMPLED_BIT)) {
        av_buffer_unref(&ref);
        return NULL;
    }
#endif
    return ref;
}

/*
 * The upload frames of software input i: in its own format when the device takes it, else
 * in nv12/p010le for 4:2:0 YUV, else in RGBA (64 bits for deep formats), which swscale
 * converts each frame to.
 */
static int config_upload(AVFilterContext *ctx, unsigned i, AVBufferRef *device)
{
    GpufxContext *s = ctx->priv;
    const AVFilterLink *link = ctx->inputs[i];
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(link->format);
    const int deep = desc->comp[0].depth > 8;
    enum AVPixelFormat cand[3] = { link->format, AV_PIX_FMT_NONE, rgba_for(link->format) };

    if (!(desc->flags & (AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_ALPHA)) && desc->nb_components == 3 &&
        desc->log2_chroma_w == 1 && desc->log2_chroma_h == 1)
        cand[1] = deep ? AV_PIX_FMT_P010 : AV_PIX_FMT_NV12;
    for (int j = 0; j < 3 && !s->up_frames[i]; j++)
        if (cand[j] != AV_PIX_FMT_NONE)
            s->up_frames[i] = upload_frames_ctx(ctx, device, cand[j], link->w, link->h);
    if (!s->up_frames[i]) {
        av_log(ctx, AV_LOG_ERROR, "Input '%s': cannot make %s frames to upload %s into.\n",
               ctx->input_pads[i].name, api_name(s->hw_fmt), desc->name);
        return AVERROR(ENOSYS);
    }
    av_log(ctx, AV_LOG_VERBOSE, "Input '%s': %s uploaded as %s %s frames.\n", ctx->input_pads[i].name,
           desc->name, api_name(s->hw_fmt),
           av_get_pix_fmt_name(((AVHWFramesContext *)s->up_frames[i]->data)->sw_format));
    return 0;
}

/* Same picture properties as src for a conversion that keeps the YUV matrix. */
static void set_same_props(AVFrame *dst, const AVFrame *src)
{
    const int field_flags = AV_FRAME_FLAG_INTERLACED | AV_FRAME_FLAG_TOP_FIELD_FIRST;

    dst->colorspace      = src->colorspace;
    dst->color_range     = src->color_range;
    dst->color_primaries = src->color_primaries;
    dst->color_trc       = src->color_trc;
    dst->chroma_location = src->chroma_location;
    dst->alpha_mode      = src->alpha_mode;
    dst->flags           = (dst->flags & ~field_flags) | (src->flags & field_flags);
}

/*
 * Uploads the software frame of input i into s->up_in[i]: as it is when the GPU converts
 * its format and colours, else converted by swscale to the upload format (or to RGBA when
 * the GPU does not convert its matrix). Effects work on straight alpha: libgpufx divides
 * premultiplied frames by alpha on the GPU (swscale keeps alpha as it is).
 */
static int upload_input(AVFilterContext *ctx, unsigned i, const AVFrame *in)
{
    GpufxContext *s = ctx->priv;
    AVBufferRef *ref = s->up_frames[i];
    const enum AVPixelFormat up = ((AVHWFramesContext *)ref->data)->sw_format;
    const AVPixFmtDescriptor *in_desc = av_pix_fmt_desc_get(in->format);
    const int matrix_ok = (in_desc->flags & AV_PIX_FMT_FLAG_RGB) || gpu_matrix(in->colorspace) >= 0;
    const AVFrame *src = in;
    int rgb = 0, ret;
    AVFrame *hw;

    if (in->format == up && matrix_ok) {
        int flipped = 0;

        for (int p = 0; p < av_pix_fmt_count_planes(in->format); p++)
            flipped |= in->linesize[p] < 0;
        /* Negative linesize (bottom-up rows): a copy flips it. */
        if (flipped) {
            if ((ret = alloc_frame(&s->conv[i], in->format, in->width, in->height)) < 0 ||
                (ret = av_frame_copy(s->conv[i], in)) < 0)
                return ret;
            src = s->conv[i];
        }
    } else {
        enum AVPixelFormat fmt = up;

        rgb = !!(av_pix_fmt_desc_get(up)->flags & AV_PIX_FMT_FLAG_RGB);
        if (!rgb && !matrix_ok) {
            /* A matrix only swscale converts: to RGBA frames, made the first time. */
            fmt = rgba_for(in->format);
            if (!s->up_rgba[i]) {
                if (!(s->up_rgba[i] = upload_frames_ctx(ctx, ((AVHWFramesContext *)ref->data)->device_ref,
                                                        fmt, in->width, in->height))) {
                    av_log(ctx, AV_LOG_ERROR, "Input '%s': cannot make %s frames of %s.\n",
                           ctx->input_pads[i].name, api_name(s->hw_fmt), av_get_pix_fmt_name(fmt));
                    return AVERROR(ENOSYS);
                }
#if CONFIG_VULKAN
                if (s->hw_fmt == AV_PIX_FMT_VULKAN && (ret = hold_vk_frames(s, s->up_rgba[i])) < 0)
                    return ret;
#endif
            }
            ref = s->up_rgba[i];
            rgb = 1;
        }
        if ((ret = alloc_frame(&s->conv[i], fmt, in->width, in->height)) < 0)
            return ret;
        if (rgb)
            set_rgba_props(s->conv[i], in);
        else
            set_same_props(s->conv[i], in);
        if ((ret = sws_convert(&s->in_sws[i], s->conv[i], in)) < 0)
            return ret;
        src = s->conv[i];
    }

    av_frame_free(&s->up_in[i]);
    if (!(hw = av_frame_alloc()))
        return AVERROR(ENOMEM);
    if ((ret = av_hwframe_get_buffer(ref, hw, 0)) < 0 ||
        (ret = av_hwframe_transfer_data(hw, src, 0)) < 0 ||
        (ret = av_frame_copy_props(hw, in)) < 0) {
        av_log(ctx, AV_LOG_ERROR, "Input '%s': upload to %s frames failed: %s\n",
               ctx->input_pads[i].name, api_name(s->hw_fmt), av_err2str(ret));
        av_frame_free(&hw);
        return ret;
    }
    if (rgb) {
        /* What the RGBA copy is; premultiplied alpha stays as the input has it. */
        hw->colorspace      = AVCOL_SPC_RGB;
        hw->color_range     = AVCOL_RANGE_JPEG;
        hw->chroma_location = AVCHROMA_LOC_UNSPECIFIED;
        hw->alpha_mode      = has_alpha(in->format) ? in->alpha_mode : AVALPHA_MODE_STRAIGHT;
    }
    s->up_in[i] = hw;
    return 0;
}

/* Frees the uploaded frames of an event. */
static void drop_uploads(GpufxContext *s)
{
    for (unsigned i = 0; s->up_in && i < s->nb_inputs; i++)
        av_frame_free(&s->up_in[i]);
}

/* Runs an event on GPU frames (info NULL: bypass). */
static int process_hw(AVFilterContext *ctx, const GpufxFrameInfo *info)
{
    GpufxContext *s = ctx->priv;

    switch (s->hw_fmt) {
#if CONFIG_VULKAN
    case AV_PIX_FMT_VULKAN: return process_vulkan(ctx, info);
#endif
#if CONFIG_D3D12VA
    case AV_PIX_FMT_D3D12:  return process_d3d12(ctx, info);
#endif
#if CONFIG_D3D11VA
    case AV_PIX_FMT_D3D11:  return process_d3d11(ctx, info);
#endif
#if CONFIG_VIDEOTOOLBOX
    case AV_PIX_FMT_VIDEOTOOLBOX: return process_videotoolbox(ctx, info);
#endif
    default:                return AVERROR_BUG;
    }
}

/*
 * The link properties are fixed after config_output, and the buffers given to
 * libgpufx have the configured sizes. A frame that differs (a library user feeding
 * frames by hand; ffmpeg itself rebuilds the graph) would overflow them.
 */
static int check_frame(AVFilterContext *ctx, unsigned i, const AVFrame *in)
{
    GpufxContext *s = ctx->priv;
    AVFilterLink *link = ctx->inputs[i];
    AVBufferRef *link_frames = ff_filter_link(link)->hw_frames_ctx;
    AVHWFramesContext *fc, *lfc;

    if (in->width != link->w || in->height != link->h || in->format != link->format) {
        av_log(ctx, AV_LOG_ERROR, "Input '%s' changed from %dx%d %s to %dx%d %s mid-stream, "
               "which gpufx does not support.\n", ctx->input_pads[i].name,
               link->w, link->h, av_get_pix_fmt_name(link->format),
               in->width, in->height, av_get_pix_fmt_name(in->format));
        return AVERROR(EINVAL);
    }
    if (s->up_frames[i])
        return 0; /* software frames, uploaded by the filter */
    if (!in->hw_frames_ctx || !link_frames) {
        av_log(ctx, AV_LOG_ERROR, "Input '%s': a GPU frame without a frames context.\n",
               ctx->input_pads[i].name);
        return AVERROR(EINVAL);
    }
    if (in->hw_frames_ctx->data == link_frames->data)
        return 0;
    /*
     * A frame of another frames context than the link's: a disabled gpufx upstream hands
     * on its own input frames (passthrough). The per-frame code reads frame->hw_frames_ctx;
     * check here what config_inputs() checked on the link's.
     */
    fc  = (AVHWFramesContext *)in->hw_frames_ctx->data;
    lfc = (AVHWFramesContext *)link_frames->data;
    if (fc->sw_format != s->hw_in_fmt[i] || fc->device_ref->data != lfc->device_ref->data) {
        av_log(ctx, AV_LOG_ERROR, "Input '%s': a frame of another frames context (%s on %s device) "
               "than the link's (%s); gpufx needs the same sw_format and device.\n",
               ctx->input_pads[i].name, av_get_pix_fmt_name(fc->sw_format),
               fc->device_ref->data == lfc->device_ref->data ? "the same" : "another",
               av_get_pix_fmt_name(s->hw_in_fmt[i]));
        return AVERROR(EINVAL);
    }
#if CONFIG_VULKAN
    if (fc->format == AV_PIX_FMT_VULKAN) {
        const AVVulkanFramesContext *vk = fc->hwctx;
        int ret;

        if ((av_pix_fmt_count_planes(fc->sw_format) > 1 && vk->format[1] == VK_FORMAT_UNDEFINED) ||
            !(vk->usage & VK_IMAGE_USAGE_SAMPLED_BIT) || gpufx_vk_host_copy_broken(fc)) {
            av_log(ctx, AV_LOG_ERROR, "Input '%s': a frame of another Vulkan frames context whose "
                   "images gpufx cannot read (multiplane, not sampled or host image copies; "
                   "image usage 0x%x).\n", ctx->input_pads[i].name, vk->usage);
            return AVERROR(ENOSYS);
        }
        /* libgpufx keeps wrappers of its images: hold it as long as the effect. */
        if ((ret = hold_vk_frames(s, in->hw_frames_ctx)) < 0)
            return ret;
    }
#endif
    return 0;
}

/* Sets what the output frame takes from the output link instead of from input 0. */
static void set_output_props(AVFrame *out, const AVFrame *in0, AVFilterLink *inlink0,
                             AVFilterLink *outlink, int64_t pts, AVRational pts_tb)
{
    out->pts       = av_rescale_q(pts, pts_tb, outlink->time_base);
    out->duration  = in0->duration > 0 ?
                     av_rescale_q(in0->duration, inlink0->time_base, outlink->time_base) : 0;
    out->time_base = outlink->time_base;
    out->sample_aspect_ratio = outlink->sample_aspect_ratio;
    out->alpha_mode          = outlink->alpha_mode;
}

/*
 * Disabled by enable= (passthrough=auto): instead of copying each source input frame into a
 * frame of the output's own frames context on the GPU, the output frame is the input's
 * texture relabelled: hw_frames_ctx is the output link's, buf[]/data[] the input's. Only for
 * the filters below, which read a frame through its hw_frames_ctx and its texture alone;
 * others (encoders, hwmap, ...) may keep the frame or rely on its pool. hwdownload and
 * gpufx_download take only frames of their link's frames context, so a plain clone of the
 * input frame would be refused or read with the wrong layout.
 */
static const char *const relabel_filters[] = { "gpufx", "gpufx_download", "hwdownload" };

/*
 * The frames contexts a gpufx output context holds (its user_opaque): the contexts of the
 * textures relabelled as its frames. A relabelled frame holds the output context, which
 * holds the context of its texture: the texture's pool (and hwcontext state its free
 * callback reads) lives until the last frame, and the last holder of the output context,
 * is gone. gpufx downstream keeps wrappers of the Vulkan images it read, keyed by VkImage,
 * while it holds the output context (hold_vk_frames): the images are not destroyed, and
 * their handles not reused, before those wrappers are.
 */
typedef struct RelabelHold {
    AVBufferRef **refs;
    int nb;
} RelabelHold;

static void relabel_hold_free(AVHWFramesContext *fc)
{
    RelabelHold *h = fc->user_opaque;

    if (!h)
        return;
    for (int i = 0; i < h->nb; i++)
        av_buffer_unref(&h->refs[i]);
    av_freep(&h->refs);
    av_freep(&fc->user_opaque);
}

/*
 * Assumes the output frames context is gpufx's own (made in config_vulkan_output() or the
 * D3D output config) and nobody else sets its free / user_opaque. hwcontext.c frees a
 * context in order pool_uninit, frames_uninit, then ctx->free, so the real input context
 * held here outlives the output's pool and frames_uninit.
 */
static int relabel_hold(AVBufferRef *out_frames, AVBufferRef *src_frames)
{
    AVHWFramesContext *ofc = (AVHWFramesContext *)out_frames->data;
    RelabelHold *h;
    AVBufferRef *ref, **list;

    if (!ofc->free) {
        if (!(ofc->user_opaque = av_mallocz(sizeof(RelabelHold))))
            return AVERROR(ENOMEM);
        ofc->free = relabel_hold_free;
    } else if (ofc->free != relabel_hold_free) {
        return AVERROR_BUG; /* gpufx makes its output contexts: never set */
    }
    h = ofc->user_opaque;
    for (int i = 0; i < h->nb; i++)
        if (h->refs[i]->data == src_frames->data)
            return 0;
    if (!(list = av_realloc_array(h->refs, h->nb + 1, sizeof(*list))))
        return AVERROR(ENOMEM);
    h->refs = list;
    if (!(ref = av_buffer_ref(src_frames)))
        return AVERROR(ENOMEM);
    h->refs[h->nb++] = ref;
    return 0;
}

/*
 * Whether the textures of frames context ifc can be read as frames of ofc (same device,
 * sw_format and size checked by the caller): what gpufx, gpufx_download and hwdownload read
 * from the frames context, they must find the same in the texture. NULL when they can,
 * else why not.
 */
static const char *relabel_compatible(AVHWFramesContext *ifc, AVHWFramesContext *ofc)
{
    if (ifc->format != ofc->format)
        return "other GPU API";
    switch (ifc->format) {
#if CONFIG_VULKAN
    case AV_PIX_FMT_VULKAN: {
        const AVVulkanFramesContext *iv = ifc->hwctx, *ov = ofc->hwctx;
        /* Read by gpufx (sampled) and copied to buffers by hwdownload and gpufx_download.
         * hwdownload takes the host image copy path when the output context has the usage
         * (gpufx drops it, gpufx_hwframe_ctx_init): then the texture needs it too. */
        const VkImageUsageFlags need = ov->usage & (VK_IMAGE_USAGE_SAMPLED_BIT |
                                                    VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                                                    VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT);

        if (iv->tiling != ov->tiling)
            return "Vulkan image tiling";
        /* One image per plane or not: format[] says it (the device's disable_multiplane
         * gives it without the flag); other flags (memory layout) must match. */
        if ((iv->flags ^ ov->flags) & ~AV_VK_FRAME_FLAG_DISABLE_MULTIPLANE)
            return "Vulkan frame flags";
        for (int j = 0; j < FF_ARRAY_ELEMS(iv->format); j++)
            if (iv->format[j] != ov->format[j])
                return "Vulkan plane formats";
        if ((need & iv->usage) != need)
            return "Vulkan image usage";
        /* Image views the readers make (mutable format, extended usage) must be allowed. */
        if ((ov->img_flags & iv->img_flags) != ov->img_flags)
            return "Vulkan image create flags";
        if (iv->create_pnext || ov->create_pnext || iv->nb_layers != ov->nb_layers)
            return "Vulkan image create chain or layers";
        /* Frames are locked through the frame's context: same functions. */
        if (iv->lock_frame != ov->lock_frame || iv->unlock_frame != ov->unlock_frame)
            return "Vulkan frame locking";
        return NULL;
    }
#endif
#if CONFIG_D3D12VA
    case AV_PIX_FMT_D3D12: {
        const AVD3D12VAFramesContext *iv = ifc->hwctx, *ov = ofc->hwctx;

        /* hwdownload copies subresources 0 and 1 of the texture in the context's format:
         * no texture arrays. */
        if (iv->format != ov->format)
            return "D3D12 texture format";
        if (iv->texture_array || ov->texture_array ||
            (iv->flags & AV_D3D12VA_FRAME_FLAG_TEXTURE_ARRAY) || (ov->flags & AV_D3D12VA_FRAME_FLAG_TEXTURE_ARRAY))
            return "D3D12 texture array";
        return NULL;
    }
#endif
#if CONFIG_D3D11VA
    case AV_PIX_FMT_D3D11:
        /* hwdownload copies subresource data[1] of texture data[0] into a staging texture of
         * the context's size and of the first texture's DXGI format (the same: same
         * sw_format); gpufx already reads this input's textures. No further D3D11 checks:
         * hwcontext_d3d11va.c's transfer takes texture and array index from the frame's
         * data[0] / data[1], and the staging texture from the shared DXGI format; a next
         * gpufx can import the texture because this gpufx already read it. */
        return NULL;
#endif
    default:
        return "GPU API without relabelling";
    }
}

/*
 * Whether a disabled event can hand every output its source input's texture relabelled as
 * an output frame (no GPU work): only when the GPU bypass would copy the pixels unchanged
 * and the next filter is in relabel_filters. All outputs or none. NULL when it can, else why
 * not (logged once).
 */
static const char *passthrough_ok(AVFilterContext *ctx)
{
    GpufxContext *s = ctx->priv;

    if (s->passthrough == PASSTHROUGH_OFF)
        return "passthrough=off";
    for (unsigned k = 0; k < s->nb_outputs; k++) {
        AVFilterLink *ol = ctx->outputs[k];
        AVBufferRef *out_frames = ff_filter_link(ol)->hw_frames_ctx;
        const int src = s->source[k];
        const AVFrame *in = s->in[src];
        const char *dst = ol->dst ? ol->dst->filter->name : "";
        const char *why;
        AVHWFramesContext *ifc, *ofc;
        int listed = 0;

        for (int j = 0; j < FF_ARRAY_ELEMS(relabel_filters); j++)
            listed |= !strcmp(dst, relabel_filters[j]);
        if (!listed)
            return "the next filter is not gpufx, gpufx_download or hwdownload";
        /* Not started (blank frame) or uploaded by the filter: no texture of its own to give. */
        if (!in || s->up_frames[src] || !in->hw_frames_ctx || !out_frames)
            return "no GPU input frame of its own";
        if (in->format != ol->format || in->width != ol->w || in->height != ol->h)
            return "another output format or size";
        ifc = (AVHWFramesContext *)in->hw_frames_ctx->data;
        ofc = (AVHWFramesContext *)out_frames->data;
        if (ifc->sw_format != ofc->sw_format || ifc->width != ofc->width ||
            ifc->height != ofc->height || ifc->device_ref->data != ofc->device_ref->data)
            return "another sw_format, size or device than the output frames";
        if (s->out_format != AV_PIX_FMT_NONE && s->out_format != ifc->sw_format)
            return "out_format";
        if (ifc != ofc && (why = relabel_compatible(ifc, ofc)))
            return why;
        /* The bypass would convert YUV to the output link's matrix and range; RGB pixels
         * do not depend on them. Unspecified alpha is read as straight. */
        if (!(av_pix_fmt_desc_get(ifc->sw_format)->flags & AV_PIX_FMT_FLAG_RGB) &&
            (in->colorspace != ol->colorspace || in->color_range != ol->color_range))
            return "another colorspace or range";
        if (has_alpha(ifc->sw_format) &&
            (in->alpha_mode == AVALPHA_MODE_PREMULTIPLIED) != (ol->alpha_mode == AVALPHA_MODE_PREMULTIPLIED))
            return "another alpha mode";
    }
    return NULL;
}

/* Hands every output its source input's texture as an output frame (passthrough_ok() said so). */
static int passthrough_frame(FFFrameSync *fs, const AVFrame *in0)
{
    AVFilterContext *ctx = fs->parent;
    GpufxContext *s = ctx->priv;
    int ret;

    if (s->logged_passthrough != 1) {
        av_log(ctx, AV_LOG_VERBOSE, "Disabled: relabelling the input frames as output frames "
               "(passthrough, no GPU copy).\n");
        s->logged_passthrough = 1;
    }
    for (unsigned k = 0; k < s->nb_outputs; k++) {
        const AVFrame *in = s->in[s->source[k]];
        AVBufferRef *out_frames = ff_filter_link(ctx->outputs[k])->hw_frames_ctx;
        AVFrame *out;

        if (in->hw_frames_ctx->data != out_frames->data &&
            (ret = relabel_hold(out_frames, in->hw_frames_ctx)) < 0)
            return ret;
        /* The input's buffers (its texture, kept alive by them) and properties and side data. */
        if (!(out = s->out[k] = av_frame_alloc()))
            return AVERROR(ENOMEM);
        if ((ret = av_frame_ref(out, in)) < 0)
            return ret;
        av_buffer_unref(&out->hw_frames_ctx);
        if (!(out->hw_frames_ctx = av_buffer_ref(out_frames)))
            return AVERROR(ENOMEM);
        /* Same pixels: only the timing and what the link fixes come from input 0 and the
         * output link. */
        set_output_props(out, in0, ctx->inputs[0], ctx->outputs[k], fs->pts, fs->time_base);
        out->colorspace  = ctx->outputs[k]->colorspace;
        out->color_range = ctx->outputs[k]->color_range;
    }
    return 0;
}

/* Frees the output frames of an event that failed or was sent. */
static void drop_outputs(GpufxContext *s)
{
    for (unsigned k = 0; k < s->nb_outputs; k++)
        av_frame_free(&s->out[k]);
}

/*
 * One event of the inputs: every output gets a frame, all made in one GPU submission and
 * sent together. Output k has the size of input s->source[k]; the timing and the other
 * properties come from input 0, which drives the events.
 */
static int process_frame(FFFrameSync *fs)
{
    AVFilterContext *ctx = fs->parent;
    GpufxContext *s = ctx->priv;
    AVFilterLink *outlink = ctx->outputs[0];
    AVFrame *in0 = NULL;
    GpufxFrameInfo info;
    double vars[VAR_NB];
    int ret, disabled;

    for (unsigned i = 0; i < s->nb_inputs; i++) {
        AVFrame *in;

        if ((ret = ff_framesync_get_frame(fs, i, &in, 0)) < 0)
            return ret;
        s->in[i] = in;
        /* Input i > 0 has not started yet (input 0 always has a frame here): process_hw()
         * takes its blank GPU frame. */
        if (!in)
            continue;
        if ((ret = check_frame(ctx, i, in)) < 0)
            return ret;
        if (i == 0)
            in0 = in;
        if ((in->flags & AV_FRAME_FLAG_INTERLACED) && !s->warned_interlaced) {
            av_log(ctx, AV_LOG_WARNING, "Input '%s' is interlaced; effects see both fields "
                   "as one frame. Deinterlace first if the effect moves or filters pixels.\n",
                   ctx->input_pads[i].name);
            s->warned_interlaced = 1;
        }
        if ((in->color_trc == AVCOL_TRC_SMPTE2084 || in->color_trc == AVCOL_TRC_ARIB_STD_B67) &&
            !s->warned_hdr) {
            av_log(ctx, AV_LOG_WARNING, "Input '%s' is HDR (%s); effects treat it as SDR "
                   "values. Tonemap it first for correct colors.\n", ctx->input_pads[i].name,
                   av_color_transfer_name(in->color_trc));
            s->warned_hdr = 1;
        }
        if (s->up_frames[i]) {
            if ((ret = upload_input(ctx, i, in)) < 0)
                return ret;
            s->in[i] = s->up_in[i];
        }
    }

    vars[VAR_T]   = fs->pts == AV_NOPTS_VALUE ? NAN : fs->pts * av_q2d(fs->time_base);
    vars[VAR_N]   = s->frame_count;
    vars[VAR_W]   = outlink->w;
    vars[VAR_H]   = outlink->h;
    vars[VAR_A]   = (double)outlink->w / outlink->h;
    vars[VAR_SAR] = outlink->sample_aspect_ratio.num ? av_q2d(outlink->sample_aspect_ratio) : 1.0;
    vars[VAR_DAR] = vars[VAR_A] * vars[VAR_SAR];
    /* Effects switched by <node>.enable; with every one off the event is a disabled one. */
    disabled = ctx->is_disabled;
    if (!disabled && s->nb_node_exprs) {
        for (int i = 0; i < s->nb_node_exprs; i++) {
            NodeExpr *e = &s->node_exprs[i];
            const int on = av_expr_eval(e->expr, vars, NULL) != 0;

            if (on != e->state) {
                if (gpufx_effect_set_node_enabled(s->fx, e->node, on) < 0) {
                    ret = gpufx_error(ctx, "enable");
                    goto fail;
                }
                e->state = on;
            }
        }
        disabled = gpufx_effect_all_nodes_disabled(s->fx);
        /* n counts on: the expressions read it. */
        s->frame_count += disabled;
    }

    if (disabled) {
        const char *why = passthrough_ok(ctx);

        if (!why) {
            if ((ret = passthrough_frame(fs, in0)) < 0)
                goto fail;
            goto send;
        }
        if (s->logged_passthrough != 2) {
            av_log(ctx, AV_LOG_VERBOSE, "Disabled: copying on the GPU (no passthrough: %s).\n", why);
            s->logged_passthrough = 2;
        }
    }

    /* GPU outputs have their own frames context: their frames are written, even disabled. */
    for (unsigned k = 0; k < s->nb_outputs; k++) {
        AVFilterLink *ol = ctx->outputs[k];
        AVFrame *out;

        if (!(out = s->out[k] = ff_get_video_buffer(ol, ol->w, ol->h))) {
            ret = AVERROR(ENOMEM);
            goto fail;
        }
        if ((ret = av_frame_copy_props(out, in0)) < 0)
            goto fail;
        set_output_props(out, in0, ctx->inputs[0], ol, fs->pts, fs->time_base);
        /* The color properties are the negotiated ones of the output link, not input 0's. */
        out->colorspace  = ol->colorspace;
        out->color_range = ol->color_range;
        /* The pixels are new: drop what describes the old ones. */
        av_frame_side_data_remove_by_props(&out->side_data, &out->nb_side_data,
                                           AV_SIDE_DATA_PROP_COLOR_DEPENDENT);
        av_frame_remove_side_data(out, AV_FRAME_DATA_MOTION_VECTORS);
        av_frame_remove_side_data(out, AV_FRAME_DATA_VIDEO_ENC_PARAMS);
    }

    if (disabled) {
        /* Pass the inputs through, converted to the output formats. */
        if ((ret = process_hw(ctx, NULL)) < 0)
            goto fail;
    } else {
        for (int i = 0; i < s->nb_exprs; i++) {
            double v = av_expr_eval(s->exprs[i].expr, vars, NULL);
            if (gpufx_effect_set_param_values(s->fx, s->exprs[i].name, &v, 1) < 0) {
                ret = gpufx_error(ctx, s->exprs[i].name);
                goto fail;
            }
        }

        info = (GpufxFrameInfo){ isnan(vars[VAR_T]) ? 0.0 : vars[VAR_T], s->frame_count, vars[VAR_SAR] };
        if ((ret = process_hw(ctx, &info)) < 0)
            goto fail;
        s->frame_count++;
    }
send:
    for (unsigned k = 0; k < s->nb_outputs; k++) {
        AVFrame *out = s->out[k];

        s->out[k] = NULL;
        /* An output closed downstream (-frames:v on its file) takes nothing more. */
        if (ff_outlink_get_status(ctx->outputs[k])) {
            av_frame_free(&out);
            continue;
        }
        if ((ret = ff_filter_frame(ctx->outputs[k], out)) < 0)
            goto fail;
    }
    drop_uploads(s);
    return 0;

fail:
    drop_outputs(s);
    drop_uploads(s);
    return ret;
}

/*
 * Inputs take GPU frames, and software frames: without a format list in the formats
 * libgpufx converts on the GPU (FFmpeg converts other formats to one of them), with a
 * list in every format swscale reads, so a frame in a format the effect does not support
 * reaches config_output and fails there. Outputs are GPU frames only.
 * Shaders work on straight alpha. The filter takes premultiplied input and gives
 * premultiplied output itself: the bundles have no premultiply_dynamic filter.
 */
static int query_formats(const AVFilterContext *ctx,
                         AVFilterFormatsConfig **cfg_in,
                         AVFilterFormatsConfig **cfg_out)
{
    static const int out_alpha[] = { AVALPHA_MODE_STRAIGHT, AVALPHA_MODE_PREMULTIPLIED, -1 };
    const GpufxContext *s = ctx->priv;
    AVFilterFormats *formats = NULL;
    enum AVPixelFormat out_hw = AV_PIX_FMT_NONE;
    int ret;

    for (unsigned i = 0; i < s->nb_inputs; i++) {
        const AVPixFmtDescriptor *desc = NULL;
        const int listed = gpufx_effect_input_format_count(s->fx, i) > 0;

        formats = NULL;
        ret = 0;
        while (ret >= 0 && (desc = av_pix_fmt_desc_next(desc))) {
            enum AVPixelFormat fmt = av_pix_fmt_desc_get_id(desc);

            if (listed ? desc->flags & (AV_PIX_FMT_FLAG_HWACCEL | AV_PIX_FMT_FLAG_BITSTREAM) ||
                         !sws_isSupportedInput(fmt)
                       : !gpufx_format_supported(desc->name))
                continue;
            ret = ff_add_format(&formats, fmt);
        }
        /* GPU frames are processed in place, whatever their sw_format (checked later). */
        if (ret >= 0)
            ret = add_hw_formats(&formats);
        if (ret < 0 || (ret = ff_formats_ref(formats, &cfg_in[i]->formats)) < 0)
            return ret;
        /* Per input: a shared list would make a premultiplied and a straight input clash. */
        if ((ret = ff_formats_ref(ff_all_alpha_modes(), &cfg_in[i]->alpha_modes)) < 0)
            return ret;
    }
    /*
     * Outputs are GPU frames only: of the API of -filter_hw_device when one is set, else of
     * any API (config_inputs() checks them against the inputs' device).
     */
    if (ctx->hw_device_ctx) {
        /* A device of another API (set for other filters of the graph) is not ours. */
        enum AVPixelFormat fmt = device_hw_format(((AVHWDeviceContext *)ctx->hw_device_ctx->data)->type);

        if (fmt != AV_PIX_FMT_NONE && hw_ok(fmt))
            out_hw = fmt;
    }
    for (unsigned k = 0; k < s->nb_outputs; k++) {
        if ((ret = ff_formats_ref(ff_make_format_list(out_alpha), &cfg_out[k]->alpha_modes)) < 0)
            return ret;
        formats = NULL;
        if ((ret = out_hw != AV_PIX_FMT_NONE ? ff_add_format(&formats, out_hw) : add_hw_formats(&formats)) < 0)
            return ret;
        if (!formats) {
            av_log((void *)ctx, AV_LOG_ERROR, "gpufx outputs GPU frames, but this build takes no Vulkan, "
                   "D3D12, D3D11 or VideoToolbox frames here.\n");
            return AVERROR(ENOSYS);
        }
        if ((ret = ff_formats_ref(formats, &cfg_out[k]->formats)) < 0)
            return ret;
    }
    return 0;
}

/* Checks every input against the manifest rules and sets up framesync; once. */
static int config_inputs(AVFilterContext *ctx)
{
    GpufxContext *s = ctx->priv;
    AVFilterLink *inlink = ctx->inputs[0];
    GpufxStreamInfo *streams;
    AVBufferRef *device = NULL; /* of the GPU inputs, else -filter_hw_device */
    unsigned nb_hw = 0;
    int ret;

    /*
     * GPU frames out, always. GPU inputs decide the API and the device (one of each);
     * software inputs are uploaded on it, or on -filter_hw_device when no input is on the GPU.
     */
    s->hw_fmt = AV_PIX_FMT_NONE;
    for (unsigned i = 0; i < s->nb_inputs; i++) {
        enum AVPixelFormat f = ctx->inputs[i]->format;
        FilterLink *l = ff_filter_link(ctx->inputs[i]);

        if (!(av_pix_fmt_desc_get(f)->flags & AV_PIX_FMT_FLAG_HWACCEL))
            continue;
        if (nb_hw++ && f != s->hw_fmt) {
            av_log(ctx, AV_LOG_ERROR, "The inputs mix %s and %s frames; gpufx runs on one device.\n",
                   api_name(s->hw_fmt), api_name(f));
            return AVERROR(EINVAL);
        }
        s->hw_fmt = f;
        if (!device && l->hw_frames_ctx)
            device = ((AVHWFramesContext *)l->hw_frames_ctx->data)->device_ref;
    }
    /*
     * -filter_hw_device must agree with the GPU inputs: its API sets the output format (see
     * query_formats()), so another API cannot run. Another device of the same API is ignored:
     * gpufx runs on the device of the GPU inputs and uploads the software inputs there.
     */
    if (device && ctx->hw_device_ctx) {
        AVHWDeviceContext *fd = (AVHWDeviceContext *)ctx->hw_device_ctx->data;
        enum AVPixelFormat ff = device_hw_format(fd->type);
        unsigned g = 0;

        while (!(av_pix_fmt_desc_get(ctx->inputs[g]->format)->flags & AV_PIX_FMT_FLAG_HWACCEL))
            g++;
        if (ff != AV_PIX_FMT_NONE && hw_ok(ff) && ff != s->hw_fmt) {
            av_log(ctx, AV_LOG_ERROR, "Input '%s' has %s frames but -filter_hw_device is a %s device; "
                   "gpufx runs on one device. Set -filter_hw_device to the device the input is decoded "
                   "on (its -hwaccel_device / -init_hw_device), or hwdownload the input.\n",
                   ctx->input_pads[g].name, api_name(s->hw_fmt), av_hwdevice_get_type_name(fd->type));
            return AVERROR(EINVAL);
        }
        if (ff == s->hw_fmt && fd != (AVHWDeviceContext *)device->data && nb_hw < s->nb_inputs)
            av_log(ctx, AV_LOG_WARNING, "Input '%s' has %s frames of another device than "
                   "-filter_hw_device; gpufx runs on the device of the input and uploads the software "
                   "inputs there.\n", ctx->input_pads[g].name, api_name(s->hw_fmt));
    }
    if (nb_hw < s->nb_inputs && !device) {
        enum AVPixelFormat f = ctx->hw_device_ctx ?
            device_hw_format(((AVHWDeviceContext *)ctx->hw_device_ctx->data)->type) : AV_PIX_FMT_NONE;

        if (f == AV_PIX_FMT_NONE || !hw_ok(f)) {
            av_log(ctx, AV_LOG_ERROR, "gpufx outputs GPU frames: add -init_hw_device "
                   "vulkan=vk:0,disable_multiplane=1 -filter_hw_device vk (or d3d12va/d3d11va/videotoolbox), "
                   "and hwdownload/gpufx_download before CPU filters or encoders.\n");
            if (ctx->hw_device_ctx)
                av_log(ctx, AV_LOG_ERROR, "The %s device of -filter_hw_device is not one gpufx "
                       "runs on (this build: %s%s%s%s).\n",
                       av_hwdevice_get_type_name(((AVHWDeviceContext *)ctx->hw_device_ctx->data)->type),
                       hw_ok(AV_PIX_FMT_VULKAN) ? "vulkan " : "", hw_ok(AV_PIX_FMT_D3D12) ? "d3d12va " : "",
                       hw_ok(AV_PIX_FMT_D3D11) ? "d3d11va " : "",
                       hw_ok(AV_PIX_FMT_VIDEOTOOLBOX) ? "videotoolbox" : "");
            return AVERROR(EINVAL);
        }
        s->hw_fmt = f;
        device = ctx->hw_device_ctx;
    }
    for (unsigned k = 0; k < s->nb_outputs; k++) {
        if (ctx->outputs[k]->format != s->hw_fmt) {
            av_log(ctx, AV_LOG_ERROR, "Output '%s' has %s frames but gpufx runs on %s frames here; "
                   "use one GPU API for the inputs, the outputs and -filter_hw_device.\n",
                   ctx->output_pads[k].name, api_name(ctx->outputs[k]->format), api_name(s->hw_fmt));
            return AVERROR(EINVAL);
        }
    }
    s->hw_in_fmt = av_calloc(s->nb_inputs, sizeof(*s->hw_in_fmt));
    s->up_frames = av_calloc(s->nb_inputs, sizeof(*s->up_frames));
    s->up_rgba   = av_calloc(s->nb_inputs, sizeof(*s->up_rgba));
    s->up_in     = av_calloc(s->nb_inputs, sizeof(*s->up_in));
    if (!s->hw_in_fmt || !s->up_frames || !s->up_rgba || !s->up_in)
        return AVERROR(ENOMEM);
    for (unsigned i = 0; i < s->nb_inputs; i++)
        if (!(av_pix_fmt_desc_get(ctx->inputs[i]->format)->flags & AV_PIX_FMT_FLAG_HWACCEL) &&
            (ret = config_upload(ctx, i, device)) < 0)
            return ret;
    if ((ret = config_api(ctx)) < 0)
        return ret;

    /* Every input is configured by now: check them all against the manifest rules. */
    streams = av_calloc(s->nb_inputs, sizeof(*streams));
    if (!streams)
        return AVERROR(ENOMEM);
    for (unsigned i = 0; i < s->nb_inputs; i++)
        streams[i] = (GpufxStreamInfo){ av_get_pix_fmt_name(s->up_frames[i] ? ctx->inputs[i]->format : s->hw_in_fmt[i]),
                                        ctx->inputs[i]->w, ctx->inputs[i]->h };
    ret = gpufx_effect_check_inputs(s->fx, streams, s->nb_inputs);
    av_free(streams);
    if (ret < 0) {
        av_log(ctx, AV_LOG_ERROR, "%s\n", gpufx_last_error());
        av_log(ctx, AV_LOG_ERROR, "Convert the input first, e.g. with the format or scale filter.\n");
        return AVERROR(EINVAL);
    }

    for (unsigned i = 0; i < s->nb_inputs; i++) {
        const AVFilterLink *link = ctx->inputs[i];
        const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(s->up_frames[i] ? link->format : s->hw_in_fmt[i]);
        AVRational sar  = link->sample_aspect_ratio.num ? link->sample_aspect_ratio : (AVRational){ 1, 1 };
        AVRational sar0 = inlink->sample_aspect_ratio.num ? inlink->sample_aspect_ratio : (AVRational){ 1, 1 };

        if (av_cmp_q(sar, sar0))
            av_log(ctx, AV_LOG_WARNING, "Input '%s' has sample aspect ratio %d:%d but the first "
                   "input %d:%d; the effect treats pixels of both as the same shape. "
                   "Use setsar or scale to match them.\n", ctx->input_pads[i].name,
                   sar.num, sar.den, sar0.num, sar0.den);
        if (desc->comp[0].depth > 10)
            av_log(ctx, AV_LOG_WARNING, "Input '%s' is %s; effects work on half float RGBA, so "
                   "precision above about 11 bits is lost.\n", ctx->input_pads[i].name, desc->name);

        /* What an input that has not started yet shows: black (opaque for formats with
         * alpha) on the GPU. */
        if (i > 0 && (ret = hw_blank(ctx, i)) < 0)
            return ret;
    }

    s->fs.opaque   = s;
    s->fs.on_event = process_frame;
    for (unsigned i = 0; i < s->nb_inputs; i++) {
        FFFrameSyncIn *in = &s->fs.in[i];

        in->time_base = ctx->inputs[i]->time_base;
        /*
         * Only frames of the first input produce output frames, so the output has its
         * frame rate; other inputs at another rate are sampled (their latest frame is
         * repeated or skipped). With equal levels, every input would emit frames and a
         * 30 fps + 25 fps pair would output both cadences mixed.
         */
        in->sync      = i == 0 ? 2 : 1;
        /* Before its first frame, an input other than the first shows the blank image. */
        in->before    = i == 0 ? EXT_STOP : EXT_NULL;
        /* The first input decides the output length; others hold their last frame. */
        in->after     = (i == 0 || s->shortest) ? EXT_STOP : EXT_INFINITY;
    }
    if ((ret = ff_framesync_configure(&s->fs)) < 0)
        return ret;
    s->configured = 1;
    return 0;
}

/*
 * Output k has the size, aspect ratio and frame rate of its source input (the first
 * input of the effect writing it); frames come at input 0's events.
 */
static int config_output(AVFilterLink *outlink)
{
    AVFilterContext *ctx = outlink->src;
    GpufxContext *s = ctx->priv;
    AVFilterLink *inlink = ctx->inputs[s->source[FF_OUTLINK_IDX(outlink)]];
    FilterLink *il = ff_filter_link(ctx->inputs[0]);
    FilterLink *ol = ff_filter_link(outlink);
    int ret;

    if (!s->configured && (ret = config_inputs(ctx)) < 0)
        return ret;

    outlink->w = inlink->w;
    outlink->h = inlink->h;
    outlink->sample_aspect_ratio = inlink->sample_aspect_ratio;
    ol->frame_rate = il->frame_rate;
    /* The output link takes input 0's side data; drop what the new pixels invalidate. */
    av_frame_side_data_remove_by_props(&outlink->side_data, &outlink->nb_side_data,
                                       AV_SIDE_DATA_PROP_COLOR_DEPENDENT);
    outlink->time_base = s->fs.time_base;
    return config_api_output(outlink, FF_OUTLINK_IDX(outlink));
}

/*
 * framesync only looks at the first output: it requests input frames only when that
 * output wants one, stops the inputs when it is closed and ends only that one. Request
 * frames for the other outputs too, close them with output 0, and keep running while
 * output 0 is open even when others are closed (their frames are dropped).
 */
static int activate(AVFilterContext *ctx)
{
    GpufxContext *s = ctx->priv;
    int ret = ff_framesync_activate(&s->fs);

    if (ret == FFERROR_NOT_READY && !ff_outlink_get_status(ctx->outputs[0])) {
        int wanted = 0;

        for (unsigned k = 1; k < s->nb_outputs; k++)
            wanted |= ff_outlink_frame_wanted(ctx->outputs[k]);
        if (wanted) {
            /* An input's status_in is set before framesync acknowledges its EOF. */
            for (unsigned i = 0; i < s->nb_inputs; i++)
                if (!ff_inlink_queued_frames(ctx->inputs[i]) && !ff_outlink_get_status(ctx->inputs[i]))
                    ff_inlink_request_frame(ctx->inputs[i]);
            return 0;
        }
    }

    if (ret >= 0 && ff_outlink_get_status(ctx->outputs[0])) {
        int64_t pts = s->fs.pts == AV_NOPTS_VALUE ? AV_NOPTS_VALUE :
                      av_rescale_q(s->fs.pts, s->fs.time_base, ctx->outputs[0]->time_base);

        for (unsigned k = 1; k < s->nb_outputs; k++)
            if (!ff_outlink_get_status(ctx->outputs[k]))
                ff_outlink_set_status(ctx->outputs[k], AVERROR_EOF, pts);
    }
    return ret;
}

static int process_command(AVFilterContext *ctx, const char *cmd, const char *args,
                           char *res, int res_len, int flags)
{
    /* "params" merges into the current values: sendcmd 'params strength=0.2' */
    if (!strcmp(cmd, "params"))
        return apply_params(ctx, args);
    return AVERROR(ENOSYS);
}

#define OFFSET(x) offsetof(GpufxContext, x)
#define FLAGS (AV_OPT_FLAG_FILTERING_PARAM | AV_OPT_FLAG_VIDEO_PARAM)

static const AVOption gpufx_options[] = {
    { "effect",   "effect package (.zip or directory), or packages chained as a.zip|b.zip", OFFSET(effect_path), AV_OPT_TYPE_STRING, { .str = NULL },   0, 0, FLAGS },
    { "graph",    "effect graph: '[0]split[a][b]; [a]x.zip[c]; [c][b]y.zip[out]'", OFFSET(graph_str),   AV_OPT_TYPE_STRING, { .str = NULL },   0, 0, FLAGS },
    { "params",   "effect parameters as name=value|name=value (package.name in a chain or graph)", OFFSET(params_str),  AV_OPT_TYPE_STRING, { .str = NULL },   0, 0, FLAGS },
    { "backend",  "GPU API (testing only, auto follows the frames): auto, vulkan, dx12", OFFSET(backend),    AV_OPT_TYPE_STRING, { .str = "auto" }, 0, 0, FLAGS },
    { "shortest", "end when the shortest input ends",                OFFSET(shortest),    AV_OPT_TYPE_BOOL,   { .i64 = 0 },      0, 1, FLAGS },
    { "out_format", "output pixel format (also the sw_format of GPU frames), e.g. rgba between chained gpufx; default: chosen from the input", OFFSET(out_format), AV_OPT_TYPE_PIXEL_FMT, { .i64 = AV_PIX_FMT_NONE }, -1, INT_MAX, FLAGS },
    { "passthrough", "when disabled by enable=, hand the input textures on without a GPU copy: auto, off", OFFSET(passthrough), AV_OPT_TYPE_INT, { .i64 = PASSTHROUGH_AUTO }, PASSTHROUGH_OFF, PASSTHROUGH_AUTO, FLAGS, .unit = "passthrough" },
        { "off",  "always copy or convert on the GPU",                                          0, AV_OPT_TYPE_CONST, { .i64 = PASSTHROUGH_OFF },  0, 0, FLAGS, .unit = "passthrough" },
        { "auto", "relabel the input frames as output frames when unchanged and the next filter is gpufx, gpufx_download or hwdownload", 0, AV_OPT_TYPE_CONST, { .i64 = PASSTHROUGH_AUTO }, 0, 0, FLAGS, .unit = "passthrough" },
    { NULL }
};

AVFILTER_DEFINE_CLASS(gpufx);

const FFFilter ff_vf_gpufx = {
    .p.name          = "gpufx",
    .p.description   = NULL_IF_CONFIG_SMALL("Apply a GPU effect package (manifest + WGSL shaders)."),
    .p.priv_class    = &gpufx_class,
    /* HWDEVICE: ffmpeg gives the filter -filter_hw_device, which software inputs go up to. */
    .p.flags         = AVFILTER_FLAG_DYNAMIC_INPUTS | AVFILTER_FLAG_DYNAMIC_OUTPUTS |
                       AVFILTER_FLAG_SUPPORT_TIMELINE_INTERNAL | AVFILTER_FLAG_HWDEVICE,
    .priv_size       = sizeof(GpufxContext),
    .flags_internal  = FF_FILTER_FLAG_HWFRAME_AWARE,
    .init            = init,
    .uninit          = uninit,
    .activate        = activate,
    .process_command = process_command,
    FILTER_QUERY_FUNC2(query_formats),
};
