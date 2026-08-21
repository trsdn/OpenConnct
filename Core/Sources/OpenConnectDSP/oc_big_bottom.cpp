/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnectDSP/oc_big_bottom.h"
#include <Accelerate/Accelerate.h>

void oc_big_bottom_init(oc_big_bottom *bottom, oc_sample_rate sr)
{
    bottom->sr = sr;
    bottom->amount = 0.0f;
    bottom->frequency = 200.0f;
    bottom->drive = 1.0f;
    oc_biquad_init_identity(&bottom->lp_in);
    oc_biquad_init_identity(&bottom->lp_out);
    oc_big_bottom_configure(bottom, 0.0f, 200.0f, 1.0f);
}

void oc_big_bottom_configure(oc_big_bottom *bottom, oc_float amount, oc_float frequency, oc_float drive)
{
    bottom->amount = oc_clampf(amount, 0.0f, 1.0f);
    bottom->frequency = frequency;
    bottom->drive = fmaxf(drive, 0.0f);

    oc_biquad_set_lowpass(&bottom->lp_in, bottom->sr, frequency, 0.707f);
    oc_biquad_set_lowpass(&bottom->lp_out, bottom->sr, frequency, 0.707f);
}

oc_float oc_big_bottom_process_sample(oc_big_bottom *bottom, oc_float input)
{
    if (bottom->amount <= 0.0f) {
        return input;
    }

    oc_float low = oc_biquad_process_sample(&bottom->lp_in, input);
    oc_float driven = low * bottom->drive * 1.8f;
    oc_float saturated = tanhf(driven);
    oc_float compressed = saturated / (1.0f + 0.6f * fabsf(saturated));
    oc_float band = oc_biquad_process_sample(&bottom->lp_out, compressed);

    return input + bottom->amount * 0.75f * band;
}

void oc_big_bottom_process_block(oc_big_bottom *bottom, const oc_float *in, oc_float *out, uint32_t n)
{
    if (bottom->amount <= 0.0f) {
        if (out != in) {
            for (uint32_t i = 0; i < n; ++i) {
                out[i] = in[i];
            }
        }
        return;
    }

    uint32_t offset = 0;

    while (offset < n) {
        oc_float wet[OC_MAX_BLOCK];
        uint32_t chunk = n - offset;

        if (chunk > OC_MAX_BLOCK) {
            chunk = OC_MAX_BLOCK;
        }

        for (uint32_t i = 0; i < chunk; ++i) {
            oc_float dry = in[offset + i];
            wet[i] = oc_big_bottom_process_sample(bottom, dry) - dry;
        }

        vDSP_vadd(wet, 1, in + offset, 1, out + offset, 1, chunk);
        offset += chunk;
    }
}
