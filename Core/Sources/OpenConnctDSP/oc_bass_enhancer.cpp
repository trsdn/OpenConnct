/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnctDSP/oc_bass_enhancer.h"
#include "oc_internal.h"
#include <Accelerate/Accelerate.h>

void oc_bass_enhancer_init(oc_bass_enhancer *bottom, oc_sample_rate sr)
{
    bottom->sr = sr;
    bottom->amount = 0.0f;
    bottom->frequency = 200.0f;
    bottom->drive = 1.0f;
    bottom->env = 0.0f;
    bottom->gain_reduction_db = 0.0f;
    bottom->attack_coeff = oc_coeff_for_ms(sr, OC_BASS_ENHANCER_ATTACK_MS);
    bottom->release_coeff = oc_coeff_for_ms(sr, OC_BASS_ENHANCER_RELEASE_MS);
    oc_biquad_init_identity(&bottom->lp_in);
    oc_biquad_init_identity(&bottom->lp_out);
    oc_bass_enhancer_configure(bottom, 0.0f, 200.0f, 1.0f);
}

void oc_bass_enhancer_configure(oc_bass_enhancer *bottom, oc_float amount, oc_float frequency, oc_float drive)
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
    bottom->threshold_lin = oc_db_to_linear(bottom->threshold_db);
}

oc_float oc_bass_enhancer_process_sample(oc_bass_enhancer *bottom, oc_float input)
{
    if (bottom->amount <= 0.0f) {
        bottom->gain_reduction_db = 0.0f;
        return input;
    }

    oc_float low = oc_biquad_process_sample(&bottom->lp_in, input);

    oc_float rectified = fabsf(low);
    oc_float coeff = rectified > bottom->env ? bottom->attack_coeff : bottom->release_coeff;
    bottom->env = oc_slew(bottom->env, rectified, coeff);

    /* Below the threshold the band passes untouched. That is the usual case --
       the envelope here is of a low-passed signal -- and taking it directly
       avoids a logarithm and an exponential that would together compute a gain
       of exactly one. */
    oc_float band_in = low;

    if (bottom->env > bottom->threshold_lin) {
        oc_float over_db = oc_linear_to_db(bottom->env) - bottom->threshold_db;
        oc_float gain_db = over_db * (1.0f / bottom->ratio - 1.0f);
        bottom->gain_reduction_db = gain_db;
        band_in = low * oc_db_to_linear(gain_db);
    } else {
        bottom->gain_reduction_db = 0.0f;
    }

    oc_float band = oc_biquad_process_sample(&bottom->lp_out, band_in);

    return input + bottom->amount * band;
}

void oc_bass_enhancer_process_block(oc_bass_enhancer *bottom, const oc_float *in, oc_float *out, uint32_t n)
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
            wet[i] = oc_bass_enhancer_process_sample(bottom, dry) - dry;
        }

        vDSP_vadd(wet, 1, in + offset, 1, out + offset, 1, chunk);
        offset += chunk;
    }
}

oc_float oc_bass_enhancer_gain_reduction_db(const oc_bass_enhancer *bottom)
{
    return bottom->gain_reduction_db;
}
