/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnectDSP/oc_biquad.h"
#include "oc_internal.h"

static void oc_biquad_set_normalized(
    oc_biquad *biquad,
    oc_float b0,
    oc_float b1,
    oc_float b2,
    oc_float a0,
    oc_float a1,
    oc_float a2)
{
    oc_float inv_a0 = 1.0f / a0;

    biquad->b0 = b0 * inv_a0;
    biquad->b1 = b1 * inv_a0;
    biquad->b2 = b2 * inv_a0;
    biquad->a1 = a1 * inv_a0;
    biquad->a2 = a2 * inv_a0;
}

void oc_biquad_init_identity(oc_biquad *biquad)
{
    biquad->b0 = 1.0f;
    biquad->b1 = 0.0f;
    biquad->b2 = 0.0f;
    biquad->a1 = 0.0f;
    biquad->a2 = 0.0f;
    biquad->z1 = 0.0f;
    biquad->z2 = 0.0f;
}

void oc_biquad_reset(oc_biquad *biquad)
{
    biquad->z1 = 0.0f;
    biquad->z2 = 0.0f;
}

oc_float oc_biquad_process_sample(oc_biquad *biquad, oc_float input)
{
    oc_float output = biquad->b0 * input + biquad->z1;

    biquad->z1 = biquad->b1 * input - biquad->a1 * output + biquad->z2;
    biquad->z2 = biquad->b2 * input - biquad->a2 * output;
    biquad->z1 = oc_flush_denormal(biquad->z1);
    biquad->z2 = oc_flush_denormal(biquad->z2);

    return output;
}

void oc_biquad_process_block(oc_biquad *biquad, const oc_float *in, oc_float *out, uint32_t n)
{
    for (uint32_t i = 0; i < n; ++i) {
        out[i] = oc_biquad_process_sample(biquad, in[i]);
    }
}

void oc_biquad_set_lowpass(oc_biquad *biquad, oc_sample_rate sr, oc_float freq, oc_float q)
{
    freq = oc_clamp_freq(sr, freq);
    q = fmaxf(q, 0.05f);

    oc_float omega = 2.0f * (oc_float)M_PI * freq / (oc_float)sr;
    oc_float cs = cosf(omega);
    oc_float sn = sinf(omega);
    oc_float alpha = sn / (2.0f * q);

    oc_biquad_set_normalized(
        biquad,
        (1.0f - cs) * 0.5f,
        1.0f - cs,
        (1.0f - cs) * 0.5f,
        1.0f + alpha,
        -2.0f * cs,
        1.0f - alpha);
}

void oc_biquad_set_highpass(oc_biquad *biquad, oc_sample_rate sr, oc_float freq, oc_float q)
{
    freq = oc_clamp_freq(sr, freq);
    q = fmaxf(q, 0.05f);

    oc_float omega = 2.0f * (oc_float)M_PI * freq / (oc_float)sr;
    oc_float cs = cosf(omega);
    oc_float sn = sinf(omega);
    oc_float alpha = sn / (2.0f * q);

    oc_biquad_set_normalized(
        biquad,
        (1.0f + cs) * 0.5f,
        -(1.0f + cs),
        (1.0f + cs) * 0.5f,
        1.0f + alpha,
        -2.0f * cs,
        1.0f - alpha);
}

void oc_biquad_set_bandpass(oc_biquad *biquad, oc_sample_rate sr, oc_float freq, oc_float q)
{
    freq = oc_clamp_freq(sr, freq);
    q = fmaxf(q, 0.05f);

    oc_float omega = 2.0f * (oc_float)M_PI * freq / (oc_float)sr;
    oc_float cs = cosf(omega);
    oc_float sn = sinf(omega);
    oc_float alpha = sn / (2.0f * q);

    oc_biquad_set_normalized(biquad, alpha, 0.0f, -alpha, 1.0f + alpha, -2.0f * cs, 1.0f - alpha);
}

void oc_biquad_set_peaking(oc_biquad *biquad, oc_sample_rate sr, oc_float freq, oc_float q, oc_float gain_db)
{
    freq = oc_clamp_freq(sr, freq);
    q = fmaxf(q, 0.05f);

    oc_float a = powf(10.0f, gain_db / 40.0f);
    oc_float omega = 2.0f * (oc_float)M_PI * freq / (oc_float)sr;
    oc_float cs = cosf(omega);
    oc_float sn = sinf(omega);
    oc_float alpha = sn / (2.0f * q);

    oc_biquad_set_normalized(
        biquad,
        1.0f + alpha * a,
        -2.0f * cs,
        1.0f - alpha * a,
        1.0f + alpha / a,
        -2.0f * cs,
        1.0f - alpha / a);
}

void oc_biquad_set_lowshelf(oc_biquad *biquad, oc_sample_rate sr, oc_float freq, oc_float slope, oc_float gain_db)
{
    freq = oc_clamp_freq(sr, freq);
    slope = fmaxf(slope, 0.1f);

    oc_float a = powf(10.0f, gain_db / 40.0f);
    oc_float omega = 2.0f * (oc_float)M_PI * freq / (oc_float)sr;
    oc_float cs = cosf(omega);
    oc_float sn = sinf(omega);
    oc_float alpha = sn * 0.5f * sqrtf((a + 1.0f / a) * (1.0f / slope - 1.0f) + 2.0f);
    oc_float beta = 2.0f * sqrtf(a) * alpha;

    oc_biquad_set_normalized(
        biquad,
        a * ((a + 1.0f) - (a - 1.0f) * cs + beta),
        2.0f * a * ((a - 1.0f) - (a + 1.0f) * cs),
        a * ((a + 1.0f) - (a - 1.0f) * cs - beta),
        (a + 1.0f) + (a - 1.0f) * cs + beta,
        -2.0f * ((a - 1.0f) + (a + 1.0f) * cs),
        (a + 1.0f) + (a - 1.0f) * cs - beta);
}

void oc_biquad_set_highshelf(oc_biquad *biquad, oc_sample_rate sr, oc_float freq, oc_float slope, oc_float gain_db)
{
    freq = oc_clamp_freq(sr, freq);
    slope = fmaxf(slope, 0.1f);

    oc_float a = powf(10.0f, gain_db / 40.0f);
    oc_float omega = 2.0f * (oc_float)M_PI * freq / (oc_float)sr;
    oc_float cs = cosf(omega);
    oc_float sn = sinf(omega);
    oc_float alpha = sn * 0.5f * sqrtf((a + 1.0f / a) * (1.0f / slope - 1.0f) + 2.0f);
    oc_float beta = 2.0f * sqrtf(a) * alpha;

    oc_biquad_set_normalized(
        biquad,
        a * ((a + 1.0f) + (a - 1.0f) * cs + beta),
        -2.0f * a * ((a - 1.0f) + (a + 1.0f) * cs),
        a * ((a + 1.0f) + (a - 1.0f) * cs - beta),
        (a + 1.0f) - (a - 1.0f) * cs + beta,
        2.0f * ((a - 1.0f) - (a + 1.0f) * cs),
        (a + 1.0f) - (a - 1.0f) * cs - beta);
}

void oc_biquad_cascade2_set_highpass(oc_biquad_cascade2 *cascade, oc_sample_rate sr, oc_float freq)
{
    oc_biquad_set_highpass(&cascade->s1, sr, freq, 0.70710678f);
    oc_biquad_set_highpass(&cascade->s2, sr, freq, 0.70710678f);
}

void oc_biquad_cascade2_reset(oc_biquad_cascade2 *cascade)
{
    oc_biquad_reset(&cascade->s1);
    oc_biquad_reset(&cascade->s2);
}

oc_float oc_biquad_cascade2_process_sample(oc_biquad_cascade2 *cascade, oc_float input)
{
    oc_float first = oc_biquad_process_sample(&cascade->s1, input);
    return oc_biquad_process_sample(&cascade->s2, first);
}
