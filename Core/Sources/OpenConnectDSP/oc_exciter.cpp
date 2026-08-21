/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnectDSP/oc_exciter.h"
#include "oc_internal.h"
#include <Accelerate/Accelerate.h>

/* Single-sided soft clipper. Both halves have unit slope at the origin so the
   stage is transparent at low level, but they saturate at different limits, so
   the transfer curve is asymmetric and generates even as well as odd harmonics.
   That asymmetry is the point of the patent's one-diode clipper. */
static inline oc_float oc_exciter_clip(oc_float u)
{
    const oc_float negative_limit = 0.55f;

    if (u >= 0.0f) {
        return tanhf(u);
    }

    return negative_limit * tanhf(u / negative_limit);
}

void oc_exciter_init(oc_exciter *exciter, oc_sample_rate sr)
{
    exciter->sr = sr;
    exciter->amount = 0.0f;
    exciter->frequency = 3000.0f;
    exciter->drive = 1.0f;
    exciter->drive_gain = 1.0f;
    exciter->env = 0.0f;
    exciter->env_attack_coeff = oc_coeff_for_ms(sr, OC_EXCITER_ENV_ATTACK_MS);
    exciter->env_release_coeff = oc_coeff_for_ms(sr, OC_EXCITER_ENV_RELEASE_MS);
    oc_biquad_init_identity(&exciter->hp1);
    oc_biquad_init_identity(&exciter->hp2);
    oc_exciter_configure(exciter, 0.0f, 3000.0f, 1.0f);
}

void oc_exciter_configure(oc_exciter *exciter, oc_float amount, oc_float frequency, oc_float drive)
{
    exciter->amount = oc_clampf(amount, 0.0f, 1.0f);
    exciter->frequency = frequency;
    exciter->drive = oc_clampf(drive, 0.0f, 1.0f);
    /* 0 -> barely into the knee, 1 -> hard clipping of every peak. */
    exciter->drive_gain = 0.6f + 5.4f * exciter->drive;

    oc_biquad_set_highpass(&exciter->hp1, exciter->sr, frequency, 0.707f);
    oc_biquad_set_highpass(&exciter->hp2, exciter->sr, frequency, 0.707f);
}

oc_float oc_exciter_process_sample(oc_exciter *exciter, oc_float input)
{
    if (exciter->amount <= 0.0f) {
        return input;
    }

    oc_float high = oc_biquad_process_sample(&exciter->hp1, input);

    oc_float rectified = fabsf(high);
    oc_float coeff = rectified > exciter->env ? exciter->env_attack_coeff : exciter->env_release_coeff;
    exciter->env = oc_slew(exciter->env, rectified, coeff);

    oc_float level = fmaxf(exciter->env, 1.0e-5f);
    oc_float driven = (high / level) * exciter->drive_gain;
    oc_float shaped = oc_exciter_clip(driven);
    /* Undo the normalisation so the stage is unity-gain below the knee; the
       second high-pass removes the DC that one-sided clipping introduces. */
    oc_float wet = shaped * level / exciter->drive_gain;
    oc_float bright = oc_biquad_process_sample(&exciter->hp2, wet);

    return input + exciter->amount * bright;
}

void oc_exciter_process_block(oc_exciter *exciter, const oc_float *in, oc_float *out, uint32_t n)
{
    if (exciter->amount <= 0.0f) {
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
            wet[i] = oc_exciter_process_sample(exciter, dry) - dry;
        }

        vDSP_vadd(wet, 1, in + offset, 1, out + offset, 1, chunk);
        offset += chunk;
    }
}
