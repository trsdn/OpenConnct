/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_BASS_ENHANCER_H
#define OC_BASS_ENHANCER_H
#include "oc_biquad.h"
#ifdef __cplusplus
extern "C" {
#endif

/* Bass enhancer: a parallel low-frequency side-chain consisting of a
   low-pass filter and a dynamics processor whose
   gain reduction rises with level. Quiet bass therefore passes at unity while
   loud bass is held back, so the blend adds weight and sustain without moving
   the peak meter much. It is a dynamics effect, not a saturator - the earlier
   tanh implementation was the wrong mechanism as well as being inaudible.

   The hardware also phase-shifts the side-chain. That is deliberately omitted:
   an all-pass in a parallel path partially cancels the dry signal at the tune
   frequency, which measurably removed low-band energy instead of adding it. */
#define OC_BASS_ENHANCER_ATTACK_MS 10.0f
#define OC_BASS_ENHANCER_RELEASE_MS 150.0f

typedef struct oc_bass_enhancer {
    oc_sample_rate sr;
    oc_float amount, frequency, drive;
    oc_biquad lp_in, lp_out;
    oc_float env, attack_coeff, release_coeff;
    oc_float threshold_db, ratio;
    oc_float gain_reduction_db;
} oc_bass_enhancer;

void oc_bass_enhancer_init(oc_bass_enhancer *b, oc_sample_rate sr);
void oc_bass_enhancer_configure(oc_bass_enhancer *b, oc_float amount, oc_float frequency, oc_float drive);
oc_float oc_bass_enhancer_process_sample(oc_bass_enhancer *b, oc_float x);
void oc_bass_enhancer_process_block(oc_bass_enhancer *b, const oc_float *in, oc_float *out, uint32_t n);
oc_float oc_bass_enhancer_gain_reduction_db(const oc_bass_enhancer *b);
#ifdef __cplusplus
}
#endif
#endif
