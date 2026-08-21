/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe: no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_RESAMPLER_H
#define OC_RESAMPLER_H
#include "oc_ring_buffer.h"
#include "oc_types.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct oc_resampler {
    double ratio;
    double phase;
    oc_float history[4];
    uint32_t history_count;
    uint32_t underrun_count;
} oc_resampler;

void oc_resampler_init(oc_resampler *r, double ratio);
void oc_resampler_reset(oc_resampler *r);
void oc_resampler_set_ratio(oc_resampler *r, double ratio);
uint32_t oc_resampler_underrun_count(const oc_resampler *r);
uint32_t oc_resampler_process(oc_resampler *r, const oc_float *in, uint32_t in_frames, oc_float *out, uint32_t out_capacity);

// Pulls exactly n_frames of output, consuming as much from src as the current ratio
// requires. Returns less than n_frames only if src underruns; the remainder of out
// is zero-filled and the underrun is counted. RT-safe.
uint32_t oc_resampler_pull(oc_resampler *r, oc_ring_buffer *src, oc_float *out, uint32_t n_frames);

#ifdef __cplusplus
}
#endif
#endif
