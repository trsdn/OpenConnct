/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnectDSP/oc_big_bottom.h"
#include "oc_internal.h"
#include <Accelerate/Accelerate.h>

void oc_big_bottom_init(oc_big_bottom *bottom, oc_sample_rate sr)
{
    bottom->sr = sr;
    bottom->amount = 0.0f;
    bottom->frequency = 200.0f;
    bottom->drive = 1.0f;
    bottom->env = 0.0f;
    bottom->gain_reduction_db = 0.0f;
    bottom->attack_coeff = oc_coeff_for_ms(sr, OC_BIG_BOTTOM_ATTACK_MS);
    bottom->release_coeff = oc_coeff_for_ms(sr, OC_BIG_BOTTOM_RELEASE_MS);
    oc_biquad_init_identity(&bottom->lp_in);
    oc_biquad_init_identity(&bottom->lp_out);
    oc_big_bottom_configure(bottom, 0.0f, 200.0f, 1.0f);
}

void oc_big_bottom_configure(oc_big_bottom *bottom, oc_float amount, oc_float frequency, oc_float drive)
{
    bottom->amount = oc_clampf(amount, 0.0f, 1.0f);
    bottom->frequency = frequency;
    bottom->drive = oc_clampf(drive, 0.0f, 1.0f);

    oc_biquad_set_lowpass(&bottom->lp_in, bottom->sr, frequency, 0.707f);
    oc_biquad_set_lowpass(&bottom->lp_out, bottom->sr, frequency, 0.707f);

    /* More drive means a lower threshold and a firmer ratio, so more of the
       band is held back and the low-level lift becomes more pronounced. */
    bottom->threshold_db = -12.0f - 24.0f * bottom->drive;
    bottom->ratio = 2.0f + 6.0f * bottom->drive;
}

oc_float oc_big_bottom_process_sample(oc_big_bottom *bottom, oc_float input)
{
    if (bottom->amount <= 0.0f) {
        bottom->gain_reduction_db = 0.0f;
        return input;
    }

    oc_float low = oc_biquad_process_sample(&bottom->lp_in, input);

    oc_float rectified = fabsf(low);
    oc_float coeff = rectified > bottom->env ? bottom->attack_coeff : bottom->release_coeff;
    bottom->env = oc_slew(bottom->env, rectified, coeff);

    oc_float level_db = oc_linear_to_db(bottom->env);
    oc_float over_db = level_db - bottom->threshold_db;
    oc_float gain_db = over_db > 0.0f ? over_db * (1.0f / bottom->ratio - 1.0f) : 0.0f;

    bottom->gain_reduction_db = gain_db;

    oc_float band = oc_biquad_process_sample(&bottom->lp_out, low * oc_db_to_linear(gain_db));

    return input + bottom->amount * band;
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

oc_float oc_big_bottom_gain_reduction_db(const oc_big_bottom *bottom)
{
    return bottom->gain_reduction_db;
}
