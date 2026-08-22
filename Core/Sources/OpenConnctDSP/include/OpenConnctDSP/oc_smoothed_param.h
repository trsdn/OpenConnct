/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_SMOOTHED_PARAM_H
#define OC_SMOOTHED_PARAM_H
#include "oc_types.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct oc_smoothed_param {
    oc_float current;
    oc_float target;
    oc_float coeff;
    oc_float epsilon;
} oc_smoothed_param;

void oc_smoothed_param_init(oc_smoothed_param *p, oc_sample_rate sr, oc_float time_ms, oc_float initial);
void oc_smoothed_param_set_time(oc_smoothed_param *p, oc_sample_rate sr, oc_float time_ms);
void oc_smoothed_param_set_target(oc_smoothed_param *p, oc_float target);
oc_float oc_smoothed_param_next(oc_smoothed_param *p);
/* Block-level render helper. May call powf once per block; do not call per sample. */
oc_float oc_smoothed_param_advance(oc_smoothed_param *p, uint32_t n);
int oc_smoothed_param_is_settled(const oc_smoothed_param *p);

#ifdef __cplusplus
}
#endif
#endif
