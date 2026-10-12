/*
 * gpufx filter: run a GPU effect package (zip with manifest.json + WGSL shaders)
 * through libgpufx. New effects need no FFmpeg rebuild: pass a different package.
 *
 * The package manifest decides which pixel formats and sizes each input accepts
 * and which formats the output may have. Inputs with a format list take frames
 * as they come and fail on a mismatch instead of being converted silently.
 * libgpufx converts the common YUV formats (NV12, P010, yuv420p...) to and from
 * the RGBA the effects work in on the GPU; other formats go through swscale.
 * graph='[0]split[a][b]; [a]x.zip[c]; [c][b]y.zip[out]' runs a whole effect graph in
 * one GPU submission, with one input pad per [N] and one output pad per label that no
 * statement reads.
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

#include "libavutil/avassert.h"
#include "libavutil/avstring.h"
#include "libavutil/eval.h"
#include "libavutil/imgutils.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"
#include "libswscale/swscale.h"

#include "avfilter.h"
#include "filters.h"
#include "formats.h"
#include "framesync.h"
#include "video.h"

static const char *const var_names[] = { "t", "n", "w", "h", "a", "sar", "dar", NULL };
enum { VAR_T, VAR_N, VAR_W, VAR_H, VAR_A, VAR_SAR, VAR_DAR, VAR_NB };

typedef struct ParamExpr {
    char *name;
    AVExpr *expr;
} ParamExpr;

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
    AVFrame **conv;   /* per-input copies: swscale RGBA conversions or flipped frames */
    SwsContext **in_sws;
    AVFrame **blank;  /* transparent image for inputs > 0 before their first frame */
    AVFrame **in;     /* frame of each input in the current event, NULL before it starts */
    GpufxFrame *frames;
    /* Per output: */
    SwsContext **out_sws;
    AVFrame **rgba_out; /* GPU result when swscale converts it to the output format */
    AVFrame **out;
    GpufxFrameOut *targets;
    int *source;        /* input pad whose size, rate and aspect ratio the output has */
    int configured;     /* inputs checked and framesync set up (by the first output) */
    FFFrameSync fs;
    int64_t frame_count;
    int warned_interlaced;
    int warned_hdr;
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

/*
 * Parses "name=value|name=value". A value is either a literal the package
 * understands ("0.5", "1,0,0", "#ff8800") or, for scalar parameters, an
 * expression of t, n, w, h, a (w/h), sar and dar evaluated for every frame
 * ("clip((t-2)/1.5,0,1)"). In a chain, names are "package.name", "index.name"
 * or a bare name only one effect has; they are stored by their full name.
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
        char *value = strchr(item, '=');
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

/* "a.zip|b.zip" opens a chain: one upload, every effect on the GPU, one readback. */
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
    av_log(ctx, AV_LOG_VERBOSE, "Loaded '%s' on %s\n",
           gpufx_effect_name(s->fx), gpufx_effect_device(s->fx));

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

    s->conv     = av_calloc(s->nb_inputs, sizeof(*s->conv));
    s->in_sws   = av_calloc(s->nb_inputs, sizeof(*s->in_sws));
    s->frames   = av_calloc(s->nb_inputs, sizeof(*s->frames));
    s->blank    = av_calloc(s->nb_inputs, sizeof(*s->blank));
    s->in       = av_calloc(s->nb_inputs, sizeof(*s->in));
    s->out_sws  = av_calloc(s->nb_outputs, sizeof(*s->out_sws));
    s->rgba_out = av_calloc(s->nb_outputs, sizeof(*s->rgba_out));
    s->out      = av_calloc(s->nb_outputs, sizeof(*s->out));
    s->targets  = av_calloc(s->nb_outputs, sizeof(*s->targets));
    s->source   = av_calloc(s->nb_outputs, sizeof(*s->source));
    if (!s->conv || !s->in_sws || !s->frames || !s->blank || !s->in ||
        !s->out_sws || !s->rgba_out || !s->out || !s->targets || !s->source)
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
    for (unsigned i = 0; s->conv && i < s->nb_inputs; i++)
        av_frame_free(&s->conv[i]);
    for (unsigned i = 0; s->in_sws && i < s->nb_inputs; i++)
        sws_free_context(&s->in_sws[i]);
    for (unsigned i = 0; s->blank && i < s->nb_inputs; i++)
        av_frame_free(&s->blank[i]);
    for (unsigned k = 0; s->out_sws && k < s->nb_outputs; k++)
        sws_free_context(&s->out_sws[k]);
    for (unsigned k = 0; s->rgba_out && k < s->nb_outputs; k++)
        av_frame_free(&s->rgba_out[k]);
    for (unsigned k = 0; s->out && k < s->nb_outputs; k++)
        av_frame_free(&s->out[k]);
    av_freep(&s->blank);
    av_freep(&s->conv);
    av_freep(&s->in_sws);
    av_freep(&s->in);
    av_freep(&s->out_sws);
    av_freep(&s->rgba_out);
    av_freep(&s->out);
    av_freep(&s->targets);
    av_freep(&s->source);
    av_freep(&s->frames);
    gpufx_effect_free(s->fx);
    s->fx = NULL;
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

static uint32_t alpha_flags(const AVFrame *f)
{
    return f->alpha_mode == AVALPHA_MODE_PREMULTIPLIED && has_alpha(f->format) ?
           GPUFX_FRAME_PREMULTIPLIED : 0;
}

/*
 * Colour properties of f for libgpufx. Returns the format name when the GPU converts
 * f as it is, or NULL when swscale must convert it (other formats or matrices).
 */
static const char *gpu_color(const AVFrame *f, GpufxColor *c)
{
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(f->format);
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
    c->flags           = alpha_flags(f);
    return desc->name;
}

/*
 * Points frames[i] at input i: the frame itself when the GPU converts its format, else
 * an RGBA copy made by swscale. Effects work on straight alpha: libgpufx divides
 * premultiplied frames by alpha on the GPU (swscale keeps alpha as it is).
 */
static int input_frame(AVFilterContext *ctx, unsigned i, AVFrame *in)
{
    GpufxContext *s = ctx->priv;
    GpufxFrame *g = &s->frames[i];
    const char *name = gpu_color(in, &g->color);
    const AVFrame *src = in;
    int ret;

    if (!name) {
        enum AVPixelFormat fmt = rgba_for(in->format);

        if ((ret = alloc_frame(&s->conv[i], fmt, in->width, in->height)) < 0)
            return ret;
        set_rgba_props(s->conv[i], in);
        if ((ret = sws_convert(&s->in_sws[i], s->conv[i], in)) < 0)
            return ret;
        name = av_get_pix_fmt_name(fmt);
        g->color = (GpufxColor){ GPUFX_MATRIX_BT601, GPUFX_RANGE_FULL, GPUFX_CHROMA_LEFT,
                                 alpha_flags(in) };
        src = s->conv[i];
    } else {
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
    }
    g->format = name;
    g->width  = src->width;
    g->height = src->height;
    for (int p = 0; p < 4; p++) {
        g->data[p]   = src->data[p];
        g->stride[p] = FFMAX(src->linesize[p], 0);
    }
    return 0;
}

/*
 * Points target at out when the GPU writes its format and colours, else at
 * s->rgba_out[k], which finish_output() then converts into out with swscale.
 */
static int output_target(GpufxContext *s, unsigned k, AVFrame *out, GpufxFrameOut *target)
{
    const char *name = gpu_color(out, &target->color);
    AVFrame *dst = out;
    int ret;

    if (!name) {
        enum AVPixelFormat fmt = rgba_for(out->format);

        if ((ret = alloc_frame(&s->rgba_out[k], fmt, out->width, out->height)) < 0)
            return ret;
        dst  = s->rgba_out[k];
        name = av_get_pix_fmt_name(fmt);
        /* Premultiplied on the GPU when the output wants it; swscale keeps alpha. */
        target->color = (GpufxColor){ GPUFX_MATRIX_BT601, GPUFX_RANGE_FULL, GPUFX_CHROMA_LEFT,
                                      alpha_flags(out) };
    }
    /* Frames we allocate have top-down rows: a negative linesize would be a huge stride. */
    av_assert0(dst->linesize[0] > 0);
    target->format = name;
    target->width  = dst->width;
    target->height = dst->height;
    for (int p = 0; p < 4; p++) {
        target->data[p]   = dst->data[p];
        target->stride[p] = FFMAX(dst->linesize[p], 0);
    }
    return 0;
}

static int finish_output(GpufxContext *s, unsigned k, AVFrame *out, const GpufxFrameOut *target)
{
    if (target->data[0] == out->data[0])
        return 0;
    set_rgba_props(s->rgba_out[k], out);
    return sws_convert(&s->out_sws[k], out, s->rgba_out[k]);
}

/*
 * The link properties are fixed after config_output, and the buffers given to
 * libgpufx have the configured sizes. A frame that differs (a library user feeding
 * frames by hand; ffmpeg itself rebuilds the graph) would overflow them.
 */
static int check_frame(AVFilterContext *ctx, unsigned i, const AVFrame *in)
{
    const AVFilterLink *link = ctx->inputs[i];

    if (in->width == link->w && in->height == link->h && in->format == link->format)
        return 0;
    av_log(ctx, AV_LOG_ERROR, "Input '%s' changed from %dx%d %s to %dx%d %s mid-stream, "
           "which gpufx does not support.\n", ctx->input_pads[i].name,
           link->w, link->h, av_get_pix_fmt_name(link->format),
           in->width, in->height, av_get_pix_fmt_name(in->format));
    return AVERROR(EINVAL);
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
    int ret, passthrough;

    for (unsigned i = 0; i < s->nb_inputs; i++) {
        AVFrame *in;

        if ((ret = ff_framesync_get_frame(fs, i, &in, 0)) < 0)
            return ret;
        s->in[i] = in;
        if (!in) {
            /* Input i > 0 has not started yet (input 0 always has a frame here). */
            const AVFrame *b = s->blank[i];
            s->frames[i] = (GpufxFrame){ "rgba", b->width, b->height, { b->data[0] },
                                         { b->linesize[0] } };
            continue;
        }
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
        if ((ret = input_frame(ctx, i, in)) < 0)
            return ret;
    }

    /* Disabled: outputs that already have their input's format are that input. */
    passthrough = ctx->is_disabled;
    for (unsigned k = 0; passthrough && k < s->nb_outputs; k++) {
        const AVFrame *src = s->in[s->source[k]];
        const AVFilterLink *ol = ctx->outputs[k];

        passthrough = src && src->format == ol->format &&
                      (src->alpha_mode == ol->alpha_mode || !has_alpha(src->format));
    }
    for (unsigned k = 0; k < s->nb_outputs; k++) {
        AVFilterLink *ol = ctx->outputs[k];
        AVFrame *out;

        if (passthrough) {
            if (!(s->out[k] = av_frame_clone(s->in[s->source[k]]))) {
                ret = AVERROR(ENOMEM);
                goto fail;
            }
            set_output_props(s->out[k], in0, ctx->inputs[0], ol, fs->pts, fs->time_base);
            continue;
        }
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
        if ((ret = output_target(s, k, out, &s->targets[k])) < 0)
            goto fail;
    }

    if (passthrough) {
        /* Nothing to run. */
    } else if (ctx->is_disabled) {
        /* Pass the inputs through, converted to the output formats. */
        if (gpufx_effect_convert_graph(s->fx, s->frames, s->nb_inputs, s->targets, s->nb_outputs) < 0) {
            ret = gpufx_error(ctx, "Conversion failed");
            goto fail;
        }
    } else {
        vars[VAR_T]   = fs->pts == AV_NOPTS_VALUE ? NAN : fs->pts * av_q2d(fs->time_base);
        vars[VAR_N]   = s->frame_count;
        vars[VAR_W]   = outlink->w;
        vars[VAR_H]   = outlink->h;
        vars[VAR_A]   = (double)outlink->w / outlink->h;
        vars[VAR_SAR] = outlink->sample_aspect_ratio.num ? av_q2d(outlink->sample_aspect_ratio) : 1.0;
        vars[VAR_DAR] = vars[VAR_A] * vars[VAR_SAR];
        for (int i = 0; i < s->nb_exprs; i++) {
            double v = av_expr_eval(s->exprs[i].expr, vars, NULL);
            if (gpufx_effect_set_param_values(s->fx, s->exprs[i].name, &v, 1) < 0) {
                ret = gpufx_error(ctx, s->exprs[i].name);
                goto fail;
            }
        }

        info = (GpufxFrameInfo){ isnan(vars[VAR_T]) ? 0.0 : vars[VAR_T], s->frame_count, vars[VAR_SAR] };
        if (gpufx_effect_process_graph(s->fx, s->frames, s->nb_inputs, s->targets, s->nb_outputs, &info) < 0) {
            ret = gpufx_error(ctx, "Processing failed");
            goto fail;
        }
        s->frame_count++;
    }
    for (unsigned k = 0; !passthrough && k < s->nb_outputs; k++)
        if ((ret = finish_output(s, k, s->out[k], &s->targets[k])) < 0)
            goto fail;
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
    return 0;

fail:
    drop_outputs(s);
    return ret;
}

/*
 * Inputs without a format list take the formats libgpufx converts on the GPU, and
 * FFmpeg converts other formats to one of them. Inputs with a list accept every
 * format swscale reads, so a frame in a format the effect does not support reaches
 * config_output and fails there.
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
        if (ret < 0 || (ret = ff_formats_ref(formats, &cfg_in[i]->formats)) < 0)
            return ret;
        /* Per input: a shared list would make a premultiplied and a straight input clash. */
        if ((ret = ff_formats_ref(ff_all_alpha_modes(), &cfg_in[i]->alpha_modes)) < 0)
            return ret;
    }
    for (unsigned k = 0; k < s->nb_outputs; k++) {
        if ((ret = ff_formats_ref(ff_make_format_list(out_alpha), &cfg_out[k]->alpha_modes)) < 0)
            return ret;
        formats = NULL;
        for (uint32_t j = 0; j < gpufx_effect_output_pad_format_count(s->fx, k); j++)
            if ((ret = ff_add_format(&formats, av_get_pix_fmt(gpufx_effect_output_pad_format(s->fx, k, j)))) < 0)
                return ret;
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
    int ret;

    /* Every input is configured by now: check them all against the manifest rules. */
    streams = av_calloc(s->nb_inputs, sizeof(*streams));
    if (!streams)
        return AVERROR(ENOMEM);
    for (unsigned i = 0; i < s->nb_inputs; i++)
        streams[i] = (GpufxStreamInfo){ av_get_pix_fmt_name(ctx->inputs[i]->format),
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
        const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(link->format);
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

        /* Transparent black, what an input that has not started yet shows. */
        if (i > 0) {
            if ((ret = alloc_frame(&s->blank[i], AV_PIX_FMT_RGBA, link->w, link->h)) < 0)
                return ret;
            for (int y = 0; y < link->h; y++)
                memset(s->blank[i]->data[0] + y * s->blank[i]->linesize[0], 0, link->w * 4);
        }
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
    return 0;
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
    { "backend",  "GPU API: auto, vulkan, dx12, metal, gl",          OFFSET(backend),     AV_OPT_TYPE_STRING, { .str = "auto" }, 0, 0, FLAGS },
    { "shortest", "end when the shortest input ends",                OFFSET(shortest),    AV_OPT_TYPE_BOOL,   { .i64 = 0 },      0, 1, FLAGS },
    { NULL }
};

AVFILTER_DEFINE_CLASS(gpufx);

const FFFilter ff_vf_gpufx = {
    .p.name          = "gpufx",
    .p.description   = NULL_IF_CONFIG_SMALL("Apply a GPU effect package (manifest + WGSL shaders)."),
    .p.priv_class    = &gpufx_class,
    .p.flags         = AVFILTER_FLAG_DYNAMIC_INPUTS | AVFILTER_FLAG_DYNAMIC_OUTPUTS |
                       AVFILTER_FLAG_SUPPORT_TIMELINE_INTERNAL,
    .priv_size       = sizeof(GpufxContext),
    .init            = init,
    .uninit          = uninit,
    .activate        = activate,
    .process_command = process_command,
    FILTER_QUERY_FUNC2(query_formats),
};
