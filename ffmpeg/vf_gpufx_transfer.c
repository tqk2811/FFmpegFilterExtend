/*
 * gpufx_upload / gpufx_download: copy frames between RAM and Vulkan frames like
 * hwupload / hwdownload, but pipelined.
 *
 * hwdownload on Vulkan (NVIDIA: no host image copy, no host memory import) records one
 * image-to-buffer copy per frame and waits for it on the CPU before returning, so the
 * GPU and the CPU take turns. gpufx_download keeps `latency` copies in flight: frame k is
 * submitted, frame k-latency (normally finished by then) is read back and sent on.
 * gpufx_upload copies each frame into one of `depth` persistently mapped staging buffers
 * and submits the buffer-to-image copy without waiting; the CPU only waits when it comes
 * back to a buffer whose copy has not finished.
 *
 * Both use FFmpeg's graphics queue family (the one gpufx and wgpu run on) and the
 * timeline semaphores of the AVVkFrames, so they mix with hwupload, hwdownload, gpufx and
 * the *_vulkan filters. Multiplane images (one VkImage, plane aspects) and one image per
 * plane (disable_multiplane=1) are both handled.
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

#include "libavutil/imgutils.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"
#include "libavutil/vulkan.h"

#include "avfilter.h"
#include "filters.h"
#include "formats.h"
#include "video.h"
#include "vf_gpufx_vk.h"

typedef struct TransferContext {
    const AVClass *class;
    int depth;    /* gpufx_upload: staging buffers in the ring */
    int latency;  /* gpufx_download: frames in flight before the first output */

    int ready;    /* vkctx, exec and the staging buffers are set up */
    FFVulkanContext vkctx;
    FFVkExecPool exec;
    FFVkBuffer *bufs;      /* one staging buffer per execution context (exec.contexts[n].idx) */
    uint8_t **mapped;
    int nb_bufs;
    AVBufferRef *frames_ref; /* gpufx_upload: the output frames context */

    enum AVPixelFormat sw_format;
    int width, height;
    int planes;
    VkBufferImageCopy region[4];
    size_t row_bytes[4];   /* bytes of one row of each plane in the sw frame */
    size_t pitch[4];       /* bytes between rows in the staging buffer */

    /* gpufx_download: submitted copies, oldest first */
    FFVkExecContext **pend_exec;
    AVFrame **pend_props;  /* the frame's properties (no data) */
    int nb_pend;
    int pend_head;
    int eof;
    int eof_status;
    int64_t eof_pts;
} TransferContext;

/* Formats whose planes map 1:1 to Vulkan planes with texels of comp[i].step bytes. */
static int transfer_fmt_ok(enum AVPixelFormat fmt)
{
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(fmt);
    int planes;

    if (!desc || desc->flags & (AV_PIX_FMT_FLAG_HWACCEL | AV_PIX_FMT_FLAG_BITSTREAM |
                                AV_PIX_FMT_FLAG_BAYER | AV_PIX_FMT_FLAG_PAL) ||
        !av_vkfmt_from_pixfmt(fmt))
        return 0;
    planes = av_pix_fmt_count_planes(fmt);
    if (planes == 1 && desc->log2_chroma_w) /* packed 4:2:2 (yuyv...): 2x1 texel blocks */
        return 0;
    for (int i = 0; i < planes; i++)
        if (desc->comp[i].plane != i || desc->comp[i].step <= 0)
            return 0;
    return 1;
}

static av_cold void transfer_uninit(AVFilterContext *ctx)
{
    TransferContext *s = ctx->priv;

    if (s->ready || s->vkctx.device_ref) {
        /* Waits for every submitted copy. */
        if (s->exec.pool_size)
            ff_vk_exec_pool_free(&s->vkctx, &s->exec);
        for (int n = 0; n < s->nb_bufs; n++) {
            if (s->mapped && s->mapped[n])
                ff_vk_unmap_buffer(&s->vkctx, &s->bufs[n], 0);
            ff_vk_free_buf(&s->vkctx, &s->bufs[n]);
        }
        ff_vk_uninit(&s->vkctx);
    }
    av_freep(&s->bufs);
    av_freep(&s->mapped);
    s->nb_bufs = 0;
    for (int n = 0; s->pend_props && n < s->latency + 1; n++)
        av_frame_free(&s->pend_props[n]);
    av_freep(&s->pend_props);
    av_freep(&s->pend_exec);
    av_buffer_unref(&s->frames_ref);
    s->ready = 0;
}

/*
 * Sets up the Vulkan context on frames_ref, an execution pool of nb_slots contexts on
 * FFmpeg's graphics queue family and one staging buffer per context, laid out as region[].
 */
static int transfer_setup(AVFilterContext *ctx, AVBufferRef *frames_ref, int width, int height,
                          int nb_slots, int upload)
{
    TransferContext *s = ctx->priv;
    AVHWFramesContext *fc = (AVHWFramesContext *)frames_ref->data;
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(fc->sw_format);
    AVVulkanDeviceQueueFamily *qf;
    VkDeviceSize row_align, off_align;
    size_t size = 0;
    int ret;

    if (!transfer_fmt_ok(fc->sw_format)) {
        av_log(ctx, AV_LOG_ERROR, "Vulkan frames of %s are not supported; use hw%s.\n",
               av_get_pix_fmt_name(fc->sw_format), upload ? "upload" : "download");
        return AVERROR(ENOSYS);
    }
    if ((ret = ff_vk_init(&s->vkctx, ctx, NULL, frames_ref)) < 0)
        return ret;
    s->sw_format = fc->sw_format;
    /* The link size: decoder frames contexts may be larger (coded size). */
    s->width     = width;
    s->height    = height;
    s->planes    = av_pix_fmt_count_planes(fc->sw_format);

    row_align = FFMAX(s->vkctx.props.properties.limits.optimalBufferCopyRowPitchAlignment, 1);
    off_align = FFMAX(s->vkctx.props.properties.limits.optimalBufferCopyOffsetAlignment, 16);
    for (int i = 0; i < s->planes; i++) {
        const int chroma = (i == 1 || i == 2) && !(desc->flags & AV_PIX_FMT_FLAG_RGB);
        const uint32_t w = chroma ? AV_CEIL_RSHIFT(s->width,  desc->log2_chroma_w) : s->width;
        const uint32_t h = chroma ? AV_CEIL_RSHIFT(s->height, desc->log2_chroma_h) : s->height;
        const int step = desc->comp[i].step;

        s->row_bytes[i] = (size_t)w * step;
        /* bufferRowLength is in texels: the pitch must stay a multiple of the texel size. */
        s->pitch[i] = FFALIGN(s->row_bytes[i], row_align);
        while (s->pitch[i] % step)
            s->pitch[i] += row_align;
        size = FFALIGN(size, off_align);
        s->region[i] = (VkBufferImageCopy) {
            .bufferOffset      = size,
            .bufferRowLength   = s->pitch[i] / step,
            .bufferImageHeight = h,
            .imageSubresource  = { .layerCount = 1 },
            .imageExtent       = (VkExtent3D){ w, h, 1 },
        };
        size += s->pitch[i] * h;
    }

    /* The family gpufx (and wgpu) submit on; see config_vulkan in vf_gpufx.c. */
    if (!(qf = ff_vk_qf_find(&s->vkctx, VK_QUEUE_GRAPHICS_BIT, 0))) {
        av_log(ctx, AV_LOG_ERROR, "The Vulkan device has no graphics queue.\n");
        return AVERROR(ENOSYS);
    }
    if ((ret = ff_vk_exec_pool_init(&s->vkctx, qf, &s->exec, nb_slots, 0, 0, 0, NULL)) < 0)
        return ret;
    /* The pool asks for the queues with the flags this libavfilter was compiled for; the
     * prebuilt libavutil may have created them with others (internally synchronized
     * queues, unknown to older Vulkan headers): a mismatch returns no queue. Only then ask
     * again with the device's own flags. */
    for (int n = 0; n < s->exec.pool_size; n++) {
        FFVkExecContext *e = &s->exec.contexts[n];
        VkDeviceQueueInfo2 info = {
            .sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_INFO_2,
            .flags            = s->vkctx.hwctx->queue_flags,
            .queueFamilyIndex = e->qf,
            .queueIndex       = e->qi,
        };
        if (e->queue)
            continue;
        s->vkctx.vkfn.GetDeviceQueue2(s->vkctx.hwctx->act_dev, &info, &e->queue);
        if (!e->queue) {
            av_log(ctx, AV_LOG_ERROR, "No queue %d of family %d.\n", e->qi, e->qf);
            return AVERROR_EXTERNAL;
        }
    }

    if (!(s->bufs = av_calloc(nb_slots, sizeof(*s->bufs))) ||
        !(s->mapped = av_calloc(nb_slots, sizeof(*s->mapped))))
        return AVERROR(ENOMEM);
    for (int n = 0; n < nb_slots; n++) {
        /* Uploads write once through (coherent, write-combined is fine); downloads read
         * with the CPU and need cached memory to be fast. */
        ret = ff_vk_create_buf(&s->vkctx, &s->bufs[n], size, NULL, NULL,
                               upload ? VK_BUFFER_USAGE_TRANSFER_SRC_BIT : VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                               VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                               (upload ? VK_MEMORY_PROPERTY_HOST_COHERENT_BIT : s->vkctx.host_cached_flag));
        if (ret < 0)
            return ret;
        s->nb_bufs++;
        if ((ret = ff_vk_map_buffer(&s->vkctx, &s->bufs[n], &s->mapped[n], 0)) < 0)
            return ret;
    }
    s->ready = 1;
    av_log(ctx, AV_LOG_VERBOSE, "%s %dx%d, %d staging buffers of %zu bytes, queue family %d\n",
           av_get_pix_fmt_name(s->sw_format), s->width, s->height, nb_slots, size, qf->idx);
    return 0;
}

/* Records the barrier and the copies of every plane of hwf; submits nothing. */
static int transfer_record(AVFilterContext *ctx, FFVkExecContext *e, AVFrame *hwf, int upload)
{
    TransferContext *s = ctx->priv;
    FFVulkanFunctions *vk = &s->vkctx.vkfn;
    AVVkFrame *vkf = (AVVkFrame *)hwf->data[0];
    const int nb_images = ff_vk_count_images(vkf);
    VkImageMemoryBarrier2 img_bar[AV_NUM_DATA_POINTERS];
    int nb_img_bar = 0;
    int ret;

    ret = ff_vk_exec_add_dep_frame(&s->vkctx, e, hwf, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
                                   VK_PIPELINE_STAGE_2_TRANSFER_BIT);
    if (ret < 0)
        return ret;
    /* Same queue family before and after: no ownership transfer. */
    ff_vk_frame_barrier(&s->vkctx, e, hwf, img_bar, &nb_img_bar,
                        VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_2_TRANSFER_BIT,
                        upload ? VK_ACCESS_2_TRANSFER_WRITE_BIT : VK_ACCESS_2_TRANSFER_READ_BIT,
                        upload ? VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL : VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                        vkf->queue_family[0]);
    vk->CmdPipelineBarrier2(e->buf, &(VkDependencyInfo) {
        .sType                   = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .pImageMemoryBarriers    = img_bar,
        .imageMemoryBarrierCount = nb_img_bar,
    });
    for (int i = 0; i < s->planes; i++) {
        const int img = FFMIN(i, nb_images - 1);
        VkBufferImageCopy region = s->region[i];

        region.imageSubresource.aspectMask = ff_vk_aspect_flag(hwf, i);
        if (upload)
            vk->CmdCopyBufferToImage(e->buf, s->bufs[e->idx].buf, vkf->img[img],
                                     VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        else
            vk->CmdCopyImageToBuffer(e->buf, vkf->img[img], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                                     s->bufs[e->idx].buf, 1, &region);
    }
    return 0;
}

static int check_size(AVFilterContext *ctx, const AVFrame *f)
{
    TransferContext *s = ctx->priv;

    if (f->width != s->width || f->height != s->height) {
        av_log(ctx, AV_LOG_ERROR, "Frame size changed from %dx%d to %dx%d.\n",
               s->width, s->height, f->width, f->height);
        return AVERROR(EINVAL);
    }
    return 0;
}

/* ---------------------------------------------------------------- gpufx_upload */

static int upload_query_formats(const AVFilterContext *ctx,
                                AVFilterFormatsConfig **cfg_in,
                                AVFilterFormatsConfig **cfg_out)
{
    static const enum AVPixelFormat out_fmts[] = { AV_PIX_FMT_VULKAN, AV_PIX_FMT_NONE };
    AVHWFramesConstraints *constraints;
    AVFilterFormats *formats = NULL;
    int ret = 0;

    if (!ctx->hw_device_ctx ||
        ((AVHWDeviceContext *)ctx->hw_device_ctx->data)->type != AV_HWDEVICE_TYPE_VULKAN) {
        av_log((void *)ctx, AV_LOG_ERROR, "gpufx_upload needs a Vulkan device: "
               "-init_hw_device vulkan=vk -filter_hw_device vk.\n");
        return AVERROR(EINVAL);
    }
    if (!(constraints = av_hwdevice_get_hwframe_constraints(ctx->hw_device_ctx, NULL)))
        return AVERROR(ENOMEM);
    for (int i = 0; constraints->valid_sw_formats &&
                    constraints->valid_sw_formats[i] != AV_PIX_FMT_NONE && ret >= 0; i++)
        if (transfer_fmt_ok(constraints->valid_sw_formats[i]))
            ret = ff_add_format(&formats, constraints->valid_sw_formats[i]);
    av_hwframe_constraints_free(&constraints);
    if (ret < 0 || (ret = ff_formats_ref(formats, &cfg_in[0]->formats)) < 0)
        return ret;
    return ff_formats_ref(ff_make_pixel_format_list(out_fmts), &cfg_out[0]->formats);
}

static int upload_config_output(AVFilterLink *outlink)
{
    AVFilterContext *ctx = outlink->src;
    TransferContext *s = ctx->priv;
    AVFilterLink *inlink = ctx->inputs[0];
    AVHWFramesContext *fc;
    int ret;

    transfer_uninit(ctx);
    if (!(s->frames_ref = av_hwframe_ctx_alloc(ctx->hw_device_ctx)))
        return AVERROR(ENOMEM);
    fc            = (AVHWFramesContext *)s->frames_ref->data;
    fc->format    = AV_PIX_FMT_VULKAN;
    fc->sw_format = inlink->format;
    fc->width     = inlink->w;
    fc->height    = inlink->h;
    /* Left at 0 the Vulkan pool grows as needed: depth frames are held by copies in
     * flight, plus whatever downstream keeps. */
    if (ctx->extra_hw_frames >= 0)
        fc->initial_pool_size = s->depth + 2 + ctx->extra_hw_frames;
    if ((ret = gpufx_hwframe_ctx_init(s->frames_ref)) < 0)
        return ret;
    if ((ret = transfer_setup(ctx, s->frames_ref, inlink->w, inlink->h, s->depth, 1)) < 0)
        return ret;
    av_buffer_unref(&ff_filter_link(outlink)->hw_frames_ctx);
    if (!(ff_filter_link(outlink)->hw_frames_ctx = av_buffer_ref(s->frames_ref)))
        return AVERROR(ENOMEM);
    return 0;
}

static int upload_filter_frame(AVFilterLink *inlink, AVFrame *in)
{
    AVFilterContext *ctx = inlink->dst;
    AVFilterLink *outlink = ctx->outputs[0];
    TransferContext *s = ctx->priv;
    FFVkExecContext *e;
    AVFrame *out = NULL;
    uint8_t *mem;
    int ret;

    if ((ret = check_size(ctx, in)) < 0)
        goto fail;
    if (!(out = ff_get_video_buffer(outlink, s->width, s->height))) {
        ret = AVERROR(ENOMEM);
        goto fail;
    }
    if ((ret = av_frame_copy_props(out, in)) < 0)
        goto fail;

    /* Waits only when this slot's previous copy has not finished. */
    e = ff_vk_exec_get(&s->vkctx, &s->exec);
    if ((ret = ff_vk_exec_start(&s->vkctx, e)) < 0)
        goto fail;
    mem = s->mapped[e->idx];
    for (int i = 0; i < s->planes; i++)
        av_image_copy_plane(mem + s->region[i].bufferOffset, s->pitch[i], in->data[i],
                            in->linesize[i], s->row_bytes[i], s->region[i].imageExtent.height);
    ff_vk_flush_buffer(&s->vkctx, &s->bufs[e->idx], 0, VK_WHOLE_SIZE, 1);

    if ((ret = transfer_record(ctx, e, out, 1)) < 0 ||
        (ret = ff_vk_exec_submit(&s->vkctx, e)) < 0) {
        ff_vk_exec_discard_deps(&s->vkctx, e);
        goto fail;
    }
    av_frame_free(&in);
    return ff_filter_frame(outlink, out);

fail:
    av_frame_free(&in);
    av_frame_free(&out);
    return ret;
}

/* -------------------------------------------------------------- gpufx_download */

static int download_query_formats(const AVFilterContext *ctx,
                                  AVFilterFormatsConfig **cfg_in,
                                  AVFilterFormatsConfig **cfg_out)
{
    static const enum AVPixelFormat in_fmts[] = { AV_PIX_FMT_VULKAN, AV_PIX_FMT_NONE };
    int ret;

    if ((ret = ff_formats_ref(ff_make_pixel_format_list(in_fmts), &cfg_in[0]->formats)) < 0)
        return ret;
    return ff_formats_ref(ff_formats_pixdesc_filter(0, AV_PIX_FMT_FLAG_HWACCEL), &cfg_out[0]->formats);
}

static int download_config_output(AVFilterLink *outlink)
{
    AVFilterContext *ctx = outlink->src;
    TransferContext *s = ctx->priv;
    FilterLink *inl = ff_filter_link(ctx->inputs[0]);
    AVHWFramesContext *fc;
    int ret;

    transfer_uninit(ctx);
    if (!inl->hw_frames_ctx) {
        av_log(ctx, AV_LOG_ERROR, "The input must have a hardware frames context.\n");
        return AVERROR(EINVAL);
    }
    fc = (AVHWFramesContext *)inl->hw_frames_ctx->data;
    if (outlink->format != fc->sw_format) {
        av_log(ctx, AV_LOG_ERROR, "Output format %s differs from the frames' %s; "
               "add format=%s after gpufx_download.\n", av_get_pix_fmt_name(outlink->format),
               av_get_pix_fmt_name(fc->sw_format), av_get_pix_fmt_name(fc->sw_format));
        return AVERROR(EINVAL);
    }
    if (!(s->pend_exec = av_calloc(s->latency + 1, sizeof(*s->pend_exec))) ||
        !(s->pend_props = av_calloc(s->latency + 1, sizeof(*s->pend_props))))
        return AVERROR(ENOMEM);
    /* latency + 1 slots: a slot is reused only after its frame has been read back. */
    if ((ret = transfer_setup(ctx, inl->hw_frames_ctx, ctx->inputs[0]->w, ctx->inputs[0]->h,
                              s->latency + 1, 0)) < 0)
        return ret;
    return 0;
}

/* Reads back the oldest submitted frame and sends it on. */
static int download_output(AVFilterContext *ctx)
{
    TransferContext *s = ctx->priv;
    AVFilterLink *outlink = ctx->outputs[0];
    FFVkExecContext *e = s->pend_exec[s->pend_head];
    AVFrame *props = s->pend_props[s->pend_head];
    AVFrame *out;
    const uint8_t *mem;
    int ret;

    s->pend_props[s->pend_head] = NULL;
    s->pend_head = (s->pend_head + 1) % (s->latency + 1);
    s->nb_pend--;

    ff_vk_exec_wait(&s->vkctx, e); /* normally finished long ago */
    if (!(out = ff_get_video_buffer(outlink, s->width, s->height))) {
        av_frame_free(&props);
        return AVERROR(ENOMEM);
    }
    ret = av_frame_copy_props(out, props);
    av_frame_free(&props);
    if (ret < 0) {
        av_frame_free(&out);
        return ret;
    }
    ff_vk_flush_buffer(&s->vkctx, &s->bufs[e->idx], 0, VK_WHOLE_SIZE, 0);
    mem = s->mapped[e->idx];
    for (int i = 0; i < s->planes; i++)
        av_image_copy_plane(out->data[i], out->linesize[i], mem + s->region[i].bufferOffset,
                            s->pitch[i], s->row_bytes[i], s->region[i].imageExtent.height);
    return ff_filter_frame(outlink, out);
}

static int download_submit(AVFilterContext *ctx, AVFrame *in)
{
    TransferContext *s = ctx->priv;
    FFVkExecContext *e;
    AVFrame *props;
    int ret;

    if ((ret = check_size(ctx, in)) < 0)
        goto end;
    if (!(props = av_frame_alloc())) {
        ret = AVERROR(ENOMEM);
        goto end;
    }
    if ((ret = av_frame_copy_props(props, in)) < 0) {
        av_frame_free(&props);
        goto end;
    }
    /* The slot's previous frame was read back already (FIFO of latency + 1). */
    e = ff_vk_exec_get(&s->vkctx, &s->exec);
    if ((ret = ff_vk_exec_start(&s->vkctx, e)) < 0 ||
        (ret = transfer_record(ctx, e, in, 0)) < 0 ||
        (ret = ff_vk_exec_submit(&s->vkctx, e)) < 0) {
        ff_vk_exec_discard_deps(&s->vkctx, e);
        av_frame_free(&props);
        goto end;
    }
    /* The execution holds a reference to the image until the copy is read back. */
    s->pend_exec[(s->pend_head + s->nb_pend) % (s->latency + 1)]  = e;
    s->pend_props[(s->pend_head + s->nb_pend) % (s->latency + 1)] = props;
    s->nb_pend++;
end:
    av_frame_free(&in);
    return ret;
}

static int download_activate(AVFilterContext *ctx)
{
    TransferContext *s = ctx->priv;
    AVFilterLink *inlink = ctx->inputs[0];
    AVFilterLink *outlink = ctx->outputs[0];
    AVFrame *in;
    int ret;

    FF_FILTER_FORWARD_STATUS_BACK(outlink, inlink);

    if (!s->eof) {
        if ((ret = ff_inlink_consume_frame(inlink, &in)) < 0)
            return ret;
        if (ret > 0) {
            if ((ret = download_submit(ctx, in)) < 0)
                return ret;
            if (s->nb_pend > s->latency && (ret = download_output(ctx)) < 0)
                return ret;
            if (ff_inlink_queued_frames(inlink))
                ff_filter_set_ready(ctx, 10);
            return 0;
        }
        if (ff_inlink_acknowledge_status(inlink, &s->eof_status, &s->eof_pts))
            s->eof = 1;
    }
    if (s->eof) {
        /* Flush the copies in flight, one per activation, then pass the status on. */
        if (s->nb_pend) {
            if ((ret = download_output(ctx)) < 0)
                return ret;
            ff_filter_set_ready(ctx, 10);
            return 0;
        }
        ff_outlink_set_status(outlink, s->eof_status, s->eof_pts);
        return 0;
    }
    FF_FILTER_FORWARD_WANTED(outlink, inlink);
    return FFERROR_NOT_READY;
}

#define OFFSET(x) offsetof(TransferContext, x)
#define FLAGS (AV_OPT_FLAG_FILTERING_PARAM | AV_OPT_FLAG_VIDEO_PARAM)

static const AVOption gpufx_upload_options[] = {
    { "depth", "staging buffers in the ring: copies in flight before the CPU waits", OFFSET(depth), AV_OPT_TYPE_INT, { .i64 = 3 }, 1, 16, FLAGS },
    { NULL }
};

AVFILTER_DEFINE_CLASS(gpufx_upload);

static const AVFilterPad upload_inputs[] = {
    {
        .name         = "default",
        .type         = AVMEDIA_TYPE_VIDEO,
        .filter_frame = upload_filter_frame,
    },
};

static const AVFilterPad upload_outputs[] = {
    {
        .name         = "default",
        .type         = AVMEDIA_TYPE_VIDEO,
        .config_props = upload_config_output,
    },
};

const FFFilter ff_vf_gpufx_upload = {
    .p.name         = "gpufx_upload",
    .p.description  = NULL_IF_CONFIG_SMALL("Upload frames to Vulkan frames without waiting for each copy."),
    .p.priv_class   = &gpufx_upload_class,
    .p.flags        = AVFILTER_FLAG_HWDEVICE,
    .priv_size      = sizeof(TransferContext),
    .uninit         = transfer_uninit,
    FILTER_INPUTS(upload_inputs),
    FILTER_OUTPUTS(upload_outputs),
    FILTER_QUERY_FUNC2(upload_query_formats),
    .flags_internal = FF_FILTER_FLAG_HWFRAME_AWARE,
};

static const AVOption gpufx_download_options[] = {
    { "latency", "frames kept in flight: frame N is sent on after frame N+latency was submitted", OFFSET(latency), AV_OPT_TYPE_INT, { .i64 = 2 }, 0, 16, FLAGS },
    { NULL }
};

AVFILTER_DEFINE_CLASS(gpufx_download);

static const AVFilterPad download_inputs[] = {
    {
        .name = "default",
        .type = AVMEDIA_TYPE_VIDEO,
    },
};

static const AVFilterPad download_outputs[] = {
    {
        .name         = "default",
        .type         = AVMEDIA_TYPE_VIDEO,
        .config_props = download_config_output,
    },
};

const FFFilter ff_vf_gpufx_download = {
    .p.name         = "gpufx_download",
    .p.description  = NULL_IF_CONFIG_SMALL("Download Vulkan frames with several copies in flight."),
    .p.priv_class   = &gpufx_download_class,
    .priv_size      = sizeof(TransferContext),
    .uninit         = transfer_uninit,
    .activate       = download_activate,
    FILTER_INPUTS(download_inputs),
    FILTER_OUTPUTS(download_outputs),
    FILTER_QUERY_FUNC2(download_query_formats),
    .flags_internal = FF_FILTER_FLAG_HWFRAME_AWARE,
};
