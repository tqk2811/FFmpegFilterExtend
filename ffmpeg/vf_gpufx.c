/*
 * gpufx filter: run a GPU effect package (zip with manifest.json + WGSL shaders)
 * through libgpufx. New effects need no FFmpeg rebuild: pass a different package.
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
#include "libavutil/mem.h"
#include "libavutil/opt.h"

#include "avfilter.h"
#include "filters.h"
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
    AVFrame **flat;   /* per-input copies used when a frame has a negative linesize */
    GpufxImage *images;
    FFFrameSync fs;
    int64_t frame_count;
} GpufxContext;

static int gpufx_error(AVFilterContext *ctx, const char *what)
{
    av_log(ctx, AV_LOG_ERROR, "%s: %s\n", what, gpufx_last_error());
    return AVERROR_EXTERNAL;
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

    s->flat   = av_calloc(s->nb_inputs, sizeof(*s->flat));
    s->images = av_calloc(s->nb_inputs, sizeof(*s->images));
    if (!s->flat || !s->images)
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
    for (unsigned i = 0; s->flat && i < s->nb_inputs; i++)
        av_frame_free(&s->flat[i]);
    av_freep(&s->flat);
    av_freep(&s->images);
    gpufx_effect_free(s->fx);
    s->fx = NULL;
}

static int process_frame(FFFrameSync *fs)
{
    AVFilterContext *ctx = fs->parent;
    GpufxContext *s = ctx->priv;
    AVFilterLink *outlink = ctx->outputs[0];
    AVFrame *in0 = NULL, *out;
    double vars[VAR_NB];
    int ret;

    for (unsigned i = 0; i < s->nb_inputs; i++) {
        AVFrame *in;

        if ((ret = ff_framesync_get_frame(fs, i, &in, 0)) < 0)
            return ret;
        if (i == 0)
            in0 = in;
        if (in->linesize[0] < 0) {
            /* libgpufx wants top-down rows; flip into a scratch frame. */
            av_frame_free(&s->flat[i]);
            s->flat[i] = ff_get_video_buffer(ctx->inputs[i], in->width, in->height);
            if (!s->flat[i])
                return AVERROR(ENOMEM);
            if ((ret = av_frame_copy(s->flat[i], in)) < 0)
                return ret;
            in = s->flat[i];
        }
        s->images[i] = (GpufxImage){ in->data[0], in->width, in->height, in->linesize[0] };
    }

    if (ctx->is_disabled) {
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

    if (gpufx_effect_process(s->fx, s->images, s->nb_inputs, out->data[0], out->linesize[0],
                             isnan(vars[VAR_T]) ? 0.0 : vars[VAR_T], s->frame_count) < 0) {
        av_frame_free(&out);
        return gpufx_error(ctx, "Processing failed");
    }
    s->frame_count++;
    return ff_filter_frame(outlink, out);
}

static int config_output(AVFilterLink *outlink)
{
    AVFilterContext *ctx = outlink->src;
    GpufxContext *s = ctx->priv;
    AVFilterLink *inlink = ctx->inputs[0];
    FilterLink *il = ff_filter_link(inlink);
    FilterLink *ol = ff_filter_link(outlink);
    int ret;

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
    FILTER_SINGLE_PIXFMT(AV_PIX_FMT_RGBA),
};
