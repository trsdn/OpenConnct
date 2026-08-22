/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnctDSP/oc_smoothed_param.h"
#include "oc_internal.h"

void oc_smoothed_param_init(oc_smoothed_param *param, oc_sample_rate sr, oc_float time_ms, oc_float initial)
{
    param->current = initial;
    param->target = initial;
    param->epsilon = 1.0e-4f;
    oc_smoothed_param_set_time(param, sr, time_ms);
}

void oc_smoothed_param_set_time(oc_smoothed_param *param, oc_sample_rate sr, oc_float time_ms)
{
    param->coeff = oc_coeff_for_ms(sr, time_ms);
}

void oc_smoothed_param_set_target(oc_smoothed_param *param, oc_float target)
{
    param->target = target;
}

oc_float oc_smoothed_param_next(oc_smoothed_param *param)
{
    if (fabsf(param->target - param->current) <= param->epsilon) {
        param->current = param->target;
        return param->current;
    }

    param->current = oc_slew(param->current, param->target, param->coeff);

    if (fabsf(param->target - param->current) <= param->epsilon) {
        param->current = param->target;
    }

    return param->current;
}

oc_float oc_smoothed_param_advance(oc_smoothed_param *param, uint32_t n)
{
    if (oc_smoothed_param_is_settled(param)) {
        return param->current;
    }

    oc_float block_coeff = powf(param->coeff, (oc_float)n);
    param->current = param->target + block_coeff * (param->current - param->target);

    if (fabsf(param->target - param->current) <= param->epsilon) {
        param->current = param->target;
    }

    return param->current;
}

int oc_smoothed_param_is_settled(const oc_smoothed_param *param)
{
    return fabsf(param->target - param->current) <= param->epsilon;
}
