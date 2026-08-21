/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_BIG_BOTTOM_H
#define OC_BIG_BOTTOM_H
#include "oc_biquad.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct oc_big_bottom { oc_sample_rate sr; oc_float amount, frequency, drive; oc_biquad lp_in, lp_out; } oc_big_bottom;
void oc_big_bottom_init(oc_big_bottom *b, oc_sample_rate sr);
void oc_big_bottom_configure(oc_big_bottom *b, oc_float amount, oc_float frequency, oc_float drive);
oc_float oc_big_bottom_process_sample(oc_big_bottom *b, oc_float x);
void oc_big_bottom_process_block(oc_big_bottom *b, const oc_float *in, oc_float *out, uint32_t n);
#ifdef __cplusplus
}
#endif
#endif
