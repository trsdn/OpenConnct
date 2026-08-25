/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnctDSP/oc_meter.h"
#include "oc_internal.h"
#include <Accelerate/Accelerate.h>

void oc_meter_init(oc_meter *meter, oc_sample_rate sr, oc_float decay_ms)
{
    meter->sr = sr;
    meter->decay_coeff = oc_coeff_for_ms(sr, decay_ms);
    oc_meter_reset(meter);
}

void oc_meter_reset(oc_meter *meter)
{
    meter->peak = 0.0f;
    meter->rms_sq = 0.0f;
}

void oc_meter_process_block(oc_meter *meter, const oc_float *in, uint32_t n)
{
    if (n == 0) {
        return;
    }

    oc_float block_peak = 0.0f;
    oc_float sum_squares = 0.0f;

    vDSP_maxmgv(in, 1, &block_peak, n);
    vDSP_svesq(in, 1, &sum_squares, n);

    oc_float block_mean_square = sum_squares / (oc_float)n;
    oc_float block_coeff = powf(meter->decay_coeff, (oc_float)n);

    meter->peak = fmaxf(block_peak, meter->peak * block_coeff);
    meter->rms_sq = (1.0f - block_coeff) * block_mean_square + block_coeff * meter->rms_sq;
}

void oc_meter_process_silence(oc_meter *meter, uint32_t n)
{
    if (n == 0) {
        return;
    }

    // The same arithmetic as process_block with an all-zero input: the block
    // peak and mean square are both zero, so only the decay term survives.
    oc_float block_coeff = powf(meter->decay_coeff, (oc_float)n);
    meter->peak *= block_coeff;
    meter->rms_sq *= block_coeff;
}

oc_meter_values oc_meter_read(const oc_meter *meter)
{
    oc_meter_values values;

    values.peak = meter->peak;
    values.rms = sqrtf(fmaxf(meter->rms_sq, 0.0f));
    values.peak_db = oc_linear_to_db(values.peak);
    values.rms_db = oc_linear_to_db(values.rms);

    return values;
}
