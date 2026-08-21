/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnectDSP/oc_exciter.h"
#include <Accelerate/Accelerate.h>

void oc_exciter_init(oc_exciter *exciter, oc_sample_rate sr)
{
    exciter->sr = sr;
    exciter->amount = 0.0f;
    exciter->frequency = 3000.0f;
    exciter->drive = 1.0f;
    oc_biquad_init_identity(&exciter->hp1);
    oc_biquad_init_identity(&exciter->hp2);
    oc_exciter_configure(exciter, 0.0f, 3000.0f, 1.0f);
}

void oc_exciter_configure(oc_exciter *exciter, oc_float amount, oc_float frequency, oc_float drive)
{
    exciter->amount = oc_clampf(amount, 0.0f, 1.0f);
    exciter->frequency = frequency;
    exciter->drive = fmaxf(drive, 0.0f);

    oc_biquad_set_highpass(&exciter->hp1, exciter->sr, frequency, 0.707f);
    oc_biquad_set_highpass(&exciter->hp2, exciter->sr, frequency, 0.707f);
}

oc_float oc_exciter_process_sample(oc_exciter *exciter, oc_float input)
{
    if (exciter->amount <= 0.0f) {
        return input;
    }

    oc_float drive = fminf(exciter->drive, 8.0f);
    oc_float high = oc_biquad_process_sample(&exciter->hp1, input) * drive;
    oc_float high_square = high * high;
    oc_float odd = tanhf(high * 1.7f);
    oc_float even = high_square / (1.0f + high_square);
    oc_float shaped = odd + 0.5f * drive * even;
    oc_float bright = oc_biquad_process_sample(&exciter->hp2, shaped);

    return input + exciter->amount * 0.25f * bright;
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
