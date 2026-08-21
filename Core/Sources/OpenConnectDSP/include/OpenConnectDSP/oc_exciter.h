/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_EXCITER_H
#define OC_EXCITER_H
#include "oc_biquad.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct oc_exciter { oc_sample_rate sr; oc_float amount, frequency, drive; oc_biquad hp1, hp2; } oc_exciter;
void oc_exciter_init(oc_exciter *e, oc_sample_rate sr);
void oc_exciter_configure(oc_exciter *e, oc_float amount, oc_float frequency, oc_float drive);
oc_float oc_exciter_process_sample(oc_exciter *e, oc_float x);
void oc_exciter_process_block(oc_exciter *e, const oc_float *in, oc_float *out, uint32_t n);
#ifdef __cplusplus
}
#endif
#endif
