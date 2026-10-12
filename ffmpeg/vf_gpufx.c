/*
 * gpufx filter: run a GPU effect package (zip with manifest.json + WGSL shaders)
 * through libgpufx. New effects need no FFmpeg rebuild: pass a different package.
 *
 * The package manifest decides which pixel formats and sizes each input accepts
 * and which formats the output may have. Inputs with a format list take frames
 * as they come and fail on a mismatch instead of being converted silently; the
 * filter converts to and from the RGBA the GPU works in with swscale.
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

static const char *const var_names[] = { "t", "n", "w", "h", NULL };
enum { VAR_T, VAR_N, VAR_W, VAR_H, VAR_NB };

typedef struct ParamExpr {
    char *name;
    AVExpr *expr;
} ParamExpr;

typedef struct GpufxContext {
    const AVClass *class;

    char *effect_path;
    char *params_str;
    char *backend;
    int shortest;

    GpufxEffect *fx;
    unsigned nb_inputs;
    ParamExpr *exprs;
    int nb_exprs;
    AVFrame **rgba;   /* per-input RGBA copies: converted or flipped frames */
    SwsContext **in_sws;
    SwsContext *out_sws;
    AVFrame *rgba_out; /* GPU result when the output format is not RGBA */
    GpufxImage *images;
    FFFrameSync fs;
    int64_t frame_count;
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

static int has_param(GpufxContext *s, const char *name)
{
    for (uint32_t i = 0; i < gpufx_effect_param_count(s->fx); i++)
        if (!strcmp(gpufx_effect_param_name(s->fx, i), name))
            return 1;
    return 0;
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
 * expression of t, n, w, h evaluated for every frame ("clip((t-2)/1.5,0,1)").
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
        AVExpr *expr = NULL;
        ParamExpr *tmp;

        if (!value) {
            av_log(ctx, AV_LOG_ERROR, "Expected name=value in params, got '%s'.\n", item);
            ret = AVERROR(EINVAL);
            break;
        }
        *value++ = 0;
        if (!has_param(s, item)) {
            av_log(ctx, AV_LOG_ERROR, "Effect '%s' has no parameter '%s'.\n",
                   gpufx_effect_name(s->fx), item);
            ret = AVERROR(EINVAL);
            break;
        }

        drop_expr(s, item);
        if (gpufx_effect_set_param(s->fx, item, value) == 0)
            continue;

        ret = av_expr_parse(&expr, value, var_names, NULL, NULL, NULL, NULL, 0, ctx);
        if (ret < 0) {
            av_log(ctx, AV_LOG_ERROR, "Invalid value for '%s': %s\n", item, gpufx_last_error());
            break;
        }
        tmp = av_realloc_array(s->exprs, s->nb_exprs + 1, sizeof(*s->exprs));
        if (!tmp) {
            av_expr_free(expr);
            ret = AVERROR(ENOMEM);
            break;
        }
        s->exprs = tmp;
        s->exprs[s->nb_exprs].name = av_strdup(item);
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

static av_cold int init(AVFilterContext *ctx)
{
    GpufxContext *s = ctx->priv;
    int ret;

    if (!s->effect_path) {
        av_log(ctx, AV_LOG_ERROR, "The 'effect' option (path to a .zip package) is required.\n");
        return AVERROR(EINVAL);
    }
    if (gpufx_version() != GPUFX_API_VERSION) {
        av_log(ctx, AV_LOG_ERROR, "libgpufx API version %u does not match headers (%u).\n",
               gpufx_version(), GPUFX_API_VERSION);
        return AVERROR(EINVAL);
    }

    s->fx = gpufx_effect_open(s->effect_path, s->backend);
    if (!s->fx)
        return gpufx_error(ctx, "Cannot load effect");
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

    for (unsigned i = 0; i < s->nb_inputs; i++)
        for (uint32_t j = 0; j < gpufx_effect_input_format_count(s->fx, i); j++)
            if ((ret = check_format_name(ctx, gpufx_effect_input_format(s->fx, i, j), 0)) < 0)
                return ret;
    for (uint32_t j = 0; j < gpufx_effect_output_format_count(s->fx); j++)
        if ((ret = check_format_name(ctx, gpufx_effect_output_format(s->fx, j), 1)) < 0)
            return ret;

    s->rgba   = av_calloc(s->nb_inputs, sizeof(*s->rgba));
    s->in_sws = av_calloc(s->nb_inputs, sizeof(*s->in_sws));
    s->images = av_calloc(s->nb_inputs, sizeof(*s->images));
    if (!s->rgba || !s->in_sws || !s->images)
        return AVERROR(ENOMEM);

    return apply_params(ctx, s->params_str);
}

static av_cold void uninit(AVFilterContext *ctx)
{
    GpufxContext *s = ctx->priv;

    ff_framesync_uninit(&s->fs);
    for (int i = 0; i < s->nb_exprs; i++)
        free_expr(&s->exprs[i]);
    av_freep(&s->exprs);
    for (unsigned i = 0; s->rgba && i < s->nb_inputs; i++)
        av_frame_free(&s->rgba[i]);
    for (unsigned i = 0; s->in_sws && i < s->nb_inputs; i++)
        sws_freeContext(s->in_sws[i]);
    av_freep(&s->rgba);
    av_freep(&s->in_sws);
    sws_freeContext(s->out_sws);
    s->out_sws = NULL;
    av_frame_free(&s->rgba_out);
    av_freep(&s->images);
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

/* Gives libgpufx a top-down RGBA view of input i, converting it if needed. */
static int input_image(AVFilterContext *ctx, unsigned i, AVFrame *in)
{
    GpufxContext *s = ctx->priv;
    AVFrame *dst;
    int ret;

    if (in->format == AV_PIX_FMT_RGBA && in->linesize[0] > 0) {
        s->images[i] = (GpufxImage){ in->data[0], in->width, in->height, in->linesize[0] };
        return 0;
    }
    if ((ret = alloc_frame(&s->rgba[i], AV_PIX_FMT_RGBA, in->width, in->height)) < 0)
        return ret;
    dst = s->rgba[i];
    if (in->format == AV_PIX_FMT_RGBA) {
        /* Negative linesize (bottom-up rows): a copy flips it. */
        if ((ret = av_frame_copy(dst, in)) < 0)
            return ret;
    } else {
        const int *coefs = sws_getCoefficients(in->colorspace == AVCOL_SPC_UNSPECIFIED ?
                                               SWS_CS_DEFAULT : in->colorspace);
        const int *rgb   = sws_getCoefficients(SWS_CS_DEFAULT);

        s->in_sws[i] = sws_getCachedContext(s->in_sws[i], in->width, in->height, in->format,
                                            in->width, in->height, AV_PIX_FMT_RGBA,
                                            SWS_BICUBIC, NULL, NULL, NULL);
        if (!s->in_sws[i])
            return AVERROR(EINVAL);
        sws_setColorspaceDetails(s->in_sws[i], coefs, in->color_range == AVCOL_RANGE_JPEG,
                                 rgb, 1, 0, 1 << 16, 1 << 16);
        ret = sws_scale(s->in_sws[i], (const uint8_t *const *)in->data, in->linesize,
                        0, in->height, dst->data, dst->linesize);
        if (ret < 0)
            return ret;
    }
    s->images[i] = (GpufxImage){ dst->data[0], dst->width, dst->height, dst->linesize[0] };
    return 0;
}

/* Converts an RGBA image into out, which has the output link format. */
static int write_output(GpufxContext *s, AVFrame *out, const uint8_t *rgba, int stride)
{
    if (out->format == AV_PIX_FMT_RGBA) {
        if (rgba != out->data[0])
            av_image_copy_plane(out->data[0], out->linesize[0], rgba, stride,
                                out->width * 4, out->height);
        return 0;
    }
    s->out_sws = sws_getCachedContext(s->out_sws, out->width, out->height, AV_PIX_FMT_RGBA,
                                      out->width, out->height, out->format,
                                      SWS_BICUBIC, NULL, NULL, NULL);
    if (!s->out_sws)
        return AVERROR(EINVAL);
    return sws_scale(s->out_sws, &rgba, &stride, 0, out->height, out->data, out->linesize);
}

static int process_frame(FFFrameSync *fs)
{
    AVFilterContext *ctx = fs->parent;
    GpufxContext *s = ctx->priv;
    AVFilterLink *outlink = ctx->outputs[0];
    AVFrame *in0 = NULL, *out;
    uint8_t *dst;
    int dst_stride;
    double vars[VAR_NB];
    int ret;

    for (unsigned i = 0; i < s->nb_inputs; i++) {
        AVFrame *in;

        if ((ret = ff_framesync_get_frame(fs, i, &in, 0)) < 0)
            return ret;
        if (i == 0)
            in0 = in;
        if ((ret = input_image(ctx, i, in)) < 0)
            return ret;
    }

    if (ctx->is_disabled && in0->format == outlink->format) {
        out = av_frame_clone(in0);
        if (!out)
            return AVERROR(ENOMEM);
        out->pts = av_rescale_q(fs->pts, fs->time_base, outlink->time_base);
        return ff_filter_frame(outlink, out);
    }

    out = ff_get_video_buffer(outlink, outlink->w, outlink->h);
    if (!out)
        return AVERROR(ENOMEM);
    av_frame_copy_props(out, in0);
    out->pts = av_rescale_q(fs->pts, fs->time_base, outlink->time_base);

    if (ctx->is_disabled) {
        /* Pass input 0 through, converted to the output format. */
        ret = write_output(s, out, s->images[0].data, s->images[0].stride);
        if (ret < 0) {
            av_frame_free(&out);
            return ret;
        }
        return ff_filter_frame(outlink, out);
    }

    vars[VAR_T] = fs->pts == AV_NOPTS_VALUE ? NAN : fs->pts * av_q2d(fs->time_base);
    vars[VAR_N] = s->frame_count;
    vars[VAR_W] = outlink->w;
    vars[VAR_H] = outlink->h;
    for (int i = 0; i < s->nb_exprs; i++) {
        double v = av_expr_eval(s->exprs[i].expr, vars, NULL);
        if (gpufx_effect_set_param_values(s->fx, s->exprs[i].name, &v, 1) < 0) {
            av_frame_free(&out);
            return gpufx_error(ctx, s->exprs[i].name);
        }
    }

    if (out->format == AV_PIX_FMT_RGBA) {
        dst        = out->data[0];
        dst_stride = out->linesize[0];
    } else {
        if ((ret = alloc_frame(&s->rgba_out, AV_PIX_FMT_RGBA, out->width, out->height)) < 0) {
            av_frame_free(&out);
            return ret;
        }
        dst        = s->rgba_out->data[0];
        dst_stride = s->rgba_out->linesize[0];
    }
    if (gpufx_effect_process(s->fx, s->images, s->nb_inputs, dst, dst_stride,
                             isnan(vars[VAR_T]) ? 0.0 : vars[VAR_T], s->frame_count) < 0) {
        av_frame_free(&out);
        return gpufx_error(ctx, "Processing failed");
    }
    if ((ret = write_output(s, out, dst, dst_stride)) < 0) {
        av_frame_free(&out);
        return ret;
    }
    s->frame_count++;
    return ff_filter_frame(outlink, out);
}

/*
 * Inputs without a format list get RGBA and FFmpeg converts for them, as before.
 * Inputs with a list accept every format swscale reads, so a frame in a format
 * the effect does not support reaches config_output and fails there.
 */
static int query_formats(const AVFilterContext *ctx,
                         AVFilterFormatsConfig **cfg_in,
                         AVFilterFormatsConfig **cfg_out)
{
    const GpufxContext *s = ctx->priv;
    AVFilterFormats *formats = NULL;
    int ret;

    for (unsigned i = 0; i < s->nb_inputs; i++) {
        formats = NULL;
        if (!gpufx_effect_input_format_count(s->fx, i)) {
            ret = ff_add_format(&formats, AV_PIX_FMT_RGBA);
        } else {
            const AVPixFmtDescriptor *desc = NULL;

            ret = 0;
            while (ret >= 0 && (desc = av_pix_fmt_desc_next(desc))) {
                enum AVPixelFormat fmt = av_pix_fmt_desc_get_id(desc);

                if (desc->flags & (AV_PIX_FMT_FLAG_HWACCEL | AV_PIX_FMT_FLAG_BITSTREAM) ||
                    !sws_isSupportedInput(fmt))
                    continue;
                ret = ff_add_format(&formats, fmt);
            }
        }
        if (ret < 0 || (ret = ff_formats_ref(formats, &cfg_in[i]->formats)) < 0)
            return ret;
    }

    formats = NULL;
    for (uint32_t j = 0; j < gpufx_effect_output_format_count(s->fx); j++)
        if ((ret = ff_add_format(&formats, av_get_pix_fmt(gpufx_effect_output_format(s->fx, j)))) < 0)
            return ret;
    return ff_formats_ref(formats, &cfg_out[0]->formats);
}

static int config_output(AVFilterLink *outlink)
{
    AVFilterContext *ctx = outlink->src;
    GpufxContext *s = ctx->priv;
    AVFilterLink *inlink = ctx->inputs[0];
    FilterLink *il = ff_filter_link(inlink);
    FilterLink *ol = ff_filter_link(outlink);
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

    outlink->w = inlink->w;
    outlink->h = inlink->h;
    outlink->sample_aspect_ratio = inlink->sample_aspect_ratio;
    ol->frame_rate = il->frame_rate;

    if ((ret = ff_framesync_init(&s->fs, ctx, s->nb_inputs)) < 0)
        return ret;
    s->fs.opaque   = s;
    s->fs.on_event = process_frame;
    for (unsigned i = 0; i < s->nb_inputs; i++) {
        FFFrameSyncIn *in = &s->fs.in[i];

        in->time_base = ctx->inputs[i]->time_base;
        in->sync      = 1;
        in->before    = EXT_STOP;
        /* The first input decides the output length; others hold their last frame. */
        in->after     = (i == 0 || s->shortest) ? EXT_STOP : EXT_INFINITY;
    }
    ret = ff_framesync_configure(&s->fs);
    outlink->time_base = s->fs.time_base;
    return ret;
}

static int activate(AVFilterContext *ctx)
{
    GpufxContext *s = ctx->priv;
    return ff_framesync_activate(&s->fs);
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
    { "effect",   "path to the effect package (.zip or directory)", OFFSET(effect_path), AV_OPT_TYPE_STRING, { .str = NULL },   0, 0, FLAGS },
    { "params",   "effect parameters as name=value|name=value",     OFFSET(params_str),  AV_OPT_TYPE_STRING, { .str = NULL },   0, 0, FLAGS },
    { "backend",  "GPU API: auto, vulkan, dx12, metal, gl",          OFFSET(backend),     AV_OPT_TYPE_STRING, { .str = "auto" }, 0, 0, FLAGS },
    { "shortest", "end when the shortest input ends",                OFFSET(shortest),    AV_OPT_TYPE_BOOL,   { .i64 = 0 },      0, 1, FLAGS },
    { NULL }
};

AVFILTER_DEFINE_CLASS(gpufx);

static const AVFilterPad gpufx_outputs[] = {
    {
        .name         = "default",
        .type         = AVMEDIA_TYPE_VIDEO,
        .config_props = config_output,
    },
};

const FFFilter ff_vf_gpufx = {
    .p.name          = "gpufx",
    .p.description   = NULL_IF_CONFIG_SMALL("Apply a GPU effect package (manifest + WGSL shaders)."),
    .p.priv_class    = &gpufx_class,
    .p.flags         = AVFILTER_FLAG_DYNAMIC_INPUTS | AVFILTER_FLAG_SUPPORT_TIMELINE_INTERNAL,
    .priv_size       = sizeof(GpufxContext),
    .init            = init,
    .uninit          = uninit,
    .activate        = activate,
    .process_command = process_command,
    FILTER_OUTPUTS(gpufx_outputs),
    FILTER_QUERY_FUNC2(query_formats),
};
