/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnctDSP/oc_compressor.h"
#include "oc_internal.h"

void oc_compressor_init(oc_compressor *compressor, oc_sample_rate sr)
{
    compressor->sr = sr;
    compressor->env = 0.0f;
    compressor->rms_sq = 0.0f;
    compressor->gain = 1.0f;
    compressor->gain_reduction_db = 0.0f;
    oc_compressor_configure(compressor, -18.0f, 3.0f, 10.0f, 100.0f, 0.0f, 0.0f, OC_DETECTOR_PEAK);
}

void oc_compressor_configure(
    oc_compressor *compressor,
    oc_float threshold_db,
    oc_float ratio,
    oc_float attack_ms,
    oc_float release_ms,
    oc_float makeup_db,
    oc_float knee_db,
    oc_detector_mode detector)
{
    compressor->threshold_db = threshold_db;
    compressor->ratio = fmaxf(ratio, 1.0f);
    compressor->attack_ms = attack_ms;
    compressor->release_ms = release_ms;
    compressor->makeup_db = makeup_db;
    compressor->knee_db = fmaxf(knee_db, 0.0f);
    compressor->detector = detector;
    compressor->attack_coeff = oc_coeff_for_ms(compressor->sr, attack_ms);
    compressor->release_coeff = oc_coeff_for_ms(compressor->sr, release_ms);
}

oc_float oc_compressor_gain_db_for_level(const oc_compressor *compressor, oc_float input_db)
{
    oc_float over_db = input_db - compressor->threshold_db;
    oc_float gain_reduction_db = 0.0f;

    if (compressor->knee_db > 0.0f && fabsf(over_db) <= compressor->knee_db * 0.5f) {
        oc_float knee_x = over_db + compressor->knee_db * 0.5f;
        gain_reduction_db = (1.0f / compressor->ratio - 1.0f) * knee_x * knee_x / (2.0f * compressor->knee_db);
    } else if (over_db > 0.0f) {
        gain_reduction_db = over_db * (1.0f / compressor->ratio - 1.0f);
    }

    return gain_reduction_db + compressor->makeup_db;
}

oc_float oc_compressor_process_sample(oc_compressor *compressor, oc_float input)
{
    oc_float level = fabsf(input);

    if (compressor->detector == OC_DETECTOR_RMS) {
        oc_float square = input * input;
        oc_float coeff = square > compressor->rms_sq ? compressor->attack_coeff : compressor->release_coeff;
        compressor->rms_sq = oc_slew(compressor->rms_sq, square, coeff);
        level = sqrtf(fmaxf(compressor->rms_sq, 0.0f));
    } else {
        oc_float coeff = level > compressor->env ? compressor->attack_coeff : compressor->release_coeff;
        compressor->env = oc_slew(compressor->env, level, coeff);
        level = compressor->env;
    }

    oc_float gain_db = oc_compressor_gain_db_for_level(compressor, oc_linear_to_db(level));

    compressor->gain = oc_db_to_linear(gain_db);
    compressor->gain_reduction_db = fminf(0.0f, gain_db - compressor->makeup_db);

    return input * compressor->gain;
}

void oc_compressor_process_block(oc_compressor *compressor, const oc_float *in, oc_float *out, uint32_t n)
{
    for (uint32_t i = 0; i < n; ++i) {
        out[i] = oc_compressor_process_sample(compressor, in[i]);
    }
}

oc_float oc_compressor_gain_reduction_db(const oc_compressor *compressor)
{
    return compressor->gain_reduction_db;
}
