/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_BIQUAD_H
#define OC_BIQUAD_H
#include "oc_types.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct oc_biquad {
    oc_float b0, b1, b2, a1, a2;
    oc_float z1, z2;
} oc_biquad;

void oc_biquad_init_identity(oc_biquad *b);
void oc_biquad_reset(oc_biquad *b);
oc_float oc_biquad_process_sample(oc_biquad *b, oc_float x);
void oc_biquad_process_block(oc_biquad *b, const oc_float *in, oc_float *out, uint32_t n);
void oc_biquad_set_lowpass(oc_biquad *b, oc_sample_rate sr, oc_float freq, oc_float q);
void oc_biquad_set_highpass(oc_biquad *b, oc_sample_rate sr, oc_float freq, oc_float q);
void oc_biquad_set_bandpass(oc_biquad *b, oc_sample_rate sr, oc_float freq, oc_float q);
void oc_biquad_set_peaking(oc_biquad *b, oc_sample_rate sr, oc_float freq, oc_float q, oc_float gain_db);
void oc_biquad_set_lowshelf(oc_biquad *b, oc_sample_rate sr, oc_float freq, oc_float slope, oc_float gain_db);
void oc_biquad_set_highshelf(oc_biquad *b, oc_sample_rate sr, oc_float freq, oc_float slope, oc_float gain_db);

typedef struct oc_biquad_cascade2 { oc_biquad s1; oc_biquad s2; } oc_biquad_cascade2;
void oc_biquad_cascade2_set_highpass(oc_biquad_cascade2 *c, oc_sample_rate sr, oc_float freq);
void oc_biquad_cascade2_reset(oc_biquad_cascade2 *c);
oc_float oc_biquad_cascade2_process_sample(oc_biquad_cascade2 *c, oc_float x);

#ifdef __cplusplus
}
#endif
#endif
