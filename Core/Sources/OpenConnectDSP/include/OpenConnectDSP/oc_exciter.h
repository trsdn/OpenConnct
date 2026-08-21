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

/* APHEX-style aural exciter, following US4150253A: split off a high-passed
   side-chain, drive it into a single-sided soft clipper (the patent's diode,
   which yields both odd and even harmonics), then blend the result back.

   The side-chain is normalised by its own envelope before the clipper. A static
   nonlinearity fed a raw mic signal sits in its linear region at speech level
   and produces no audible harmonics at all; normalising makes the harmonic
   character independent of how loud the source happens to be. */
#define OC_EXCITER_ENV_ATTACK_MS 5.0f
#define OC_EXCITER_ENV_RELEASE_MS 120.0f

typedef struct oc_exciter {
    oc_sample_rate sr;
    oc_float amount, frequency, drive;
    oc_float drive_gain;
    oc_biquad hp1, hp2;
    oc_float env;
    oc_float env_attack_coeff, env_release_coeff;
} oc_exciter;

void oc_exciter_init(oc_exciter *e, oc_sample_rate sr);
void oc_exciter_configure(oc_exciter *e, oc_float amount, oc_float frequency, oc_float drive);
oc_float oc_exciter_process_sample(oc_exciter *e, oc_float x);
void oc_exciter_process_block(oc_exciter *e, const oc_float *in, oc_float *out, uint32_t n);
#ifdef __cplusplus
}
#endif
#endif
