/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe: no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnctDSP/oc_resampler.h"
#include <math.h>

static oc_float oc_resampler_catmull_rom(oc_float y0, oc_float y1, oc_float y2, oc_float y3, oc_float t)
{
    oc_float t2 = t * t;
    oc_float t3 = t2 * t;

    return 0.5f * ((2.0f * y1)
        + (-y0 + y2) * t
        + (2.0f * y0 - 5.0f * y1 + 4.0f * y2 - y3) * t2
        + (-y0 + 3.0f * y1 - 3.0f * y2 + y3) * t3);
}

static void oc_resampler_clear_history(oc_resampler *resampler)
{
    resampler->phase = 1.0;
    resampler->history_count = 0u;

    for (uint32_t i = 0; i < 4u; ++i) {
        resampler->history[i] = 0.0f;
    }
}

static int oc_resampler_bootstrap_from_ring(oc_resampler *resampler, oc_ring_buffer *src)
{
    oc_float first[3];

    if (oc_ring_buffer_available_read(src) < 3u) {
        return 0;
    }

    if (oc_ring_buffer_read(src, first, 3u) != 3u) {
        return 0;
    }

    resampler->history[0] = first[0];
    resampler->history[1] = first[0];
    resampler->history[2] = first[1];
    resampler->history[3] = first[2];
    resampler->history_count = 4u;
    resampler->phase = 1.0;

    return 1;
}

static int oc_resampler_shift_from_ring(oc_resampler *resampler, oc_ring_buffer *src)
{
    oc_float next = 0.0f;

    if (oc_ring_buffer_read(src, &next, 1u) != 1u) {
        return 0;
    }

    resampler->history[0] = resampler->history[1];
    resampler->history[1] = resampler->history[2];
    resampler->history[2] = resampler->history[3];
    resampler->history[3] = next;

    return 1;
}

static int oc_resampler_bootstrap_from_buffer(oc_resampler *resampler, const oc_float *in, uint32_t in_frames, uint32_t *consumed)
{
    if (in_frames < 3u) {
        return 0;
    }

    resampler->history[0] = in[0];
    resampler->history[1] = in[0];
    resampler->history[2] = in[1];
    resampler->history[3] = in[2];
    resampler->history_count = 4u;
    resampler->phase = 1.0;
    *consumed = 3u;

    return 1;
}

static int oc_resampler_shift_from_buffer(
    oc_resampler *resampler,
    const oc_float *in,
    uint32_t in_frames,
    uint32_t *consumed)
{
    if (*consumed >= in_frames) {
        return 0;
    }

    resampler->history[0] = resampler->history[1];
    resampler->history[1] = resampler->history[2];
    resampler->history[2] = resampler->history[3];
    resampler->history[3] = in[*consumed];
    ++(*consumed);

    return 1;
}

void oc_resampler_init(oc_resampler *resampler, double ratio)
{
    resampler->ratio = ratio;
    resampler->underrun_count = 0u;
    oc_resampler_clear_history(resampler);
}

void oc_resampler_reset(oc_resampler *resampler)
{
    resampler->underrun_count = 0u;
    oc_resampler_clear_history(resampler);
}

void oc_resampler_set_ratio(oc_resampler *resampler, double ratio)
{
    resampler->ratio = ratio;
}

uint32_t oc_resampler_underrun_count(const oc_resampler *resampler)
{
    return resampler->underrun_count;
}

uint32_t oc_resampler_process(
    oc_resampler *resampler,
    const oc_float *in,
    uint32_t in_frames,
    oc_float *out,
    uint32_t out_capacity)
{
    uint32_t produced = 0u;
    uint32_t consumed = 0u;

    if (in_frames == 0u || resampler->ratio <= 0.0) {
        return 0u;
    }

    if (resampler->history_count < 4u) {
        if (!oc_resampler_bootstrap_from_buffer(resampler, in, in_frames, &consumed)) {
            return 0u;
        }
    }

    while (produced < out_capacity) {
        while (resampler->phase >= 2.0) {
            if (!oc_resampler_shift_from_buffer(resampler, in, in_frames, &consumed)) {
                return produced;
            }

            resampler->phase -= 1.0;
        }

        oc_float t = (oc_float)(resampler->phase - 1.0);
        out[produced] = oc_resampler_catmull_rom(
            resampler->history[0],
            resampler->history[1],
            resampler->history[2],
            resampler->history[3],
            t);

        ++produced;
        resampler->phase += resampler->ratio;
    }

    return produced;
}

uint32_t oc_resampler_pull(oc_resampler *resampler, oc_ring_buffer *src, oc_float *out, uint32_t n_frames)
{
    uint32_t produced = 0u;

    if (resampler->ratio <= 0.0) {
        for (uint32_t i = 0; i < n_frames; ++i) {
            out[i] = 0.0f;
        }
        ++resampler->underrun_count;
        oc_resampler_clear_history(resampler);
        return 0u;
    }

    if (resampler->history_count < 4u) {
        if (!oc_resampler_bootstrap_from_ring(resampler, src)) {
            for (uint32_t i = 0; i < n_frames; ++i) {
                out[i] = 0.0f;
            }
            ++resampler->underrun_count;
            oc_resampler_clear_history(resampler);
            return 0u;
        }
    }

    while (produced < n_frames) {
        while (resampler->phase >= 2.0) {
            if (!oc_resampler_shift_from_ring(resampler, src)) {
                for (uint32_t i = produced; i < n_frames; ++i) {
                    out[i] = 0.0f;
                }
                ++resampler->underrun_count;
                oc_resampler_clear_history(resampler);
                return produced;
            }

            resampler->phase -= 1.0;
        }

        oc_float t = (oc_float)(resampler->phase - 1.0);
        out[produced] = oc_resampler_catmull_rom(
            resampler->history[0],
            resampler->history[1],
            resampler->history[2],
            resampler->history[3],
            t);

        ++produced;
        resampler->phase += resampler->ratio;
    }

    return produced;
}
