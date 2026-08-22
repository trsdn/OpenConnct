/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_TYPES_H
#define OC_TYPES_H
#include <math.h>
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef float oc_float;
typedef double oc_sample_rate;
enum { OC_MAX_BLOCK = 1024 };

static inline oc_float oc_db_to_linear(oc_float db) { return powf(10.0f, db / 20.0f); }
static inline oc_float oc_linear_to_db(oc_float x) { return 20.0f * log10f(fmaxf(fabsf(x), 1.0e-20f)); }
static inline oc_float oc_clampf(oc_float x, oc_float lo, oc_float hi) { return fminf(fmaxf(x, lo), hi); }
static inline oc_float oc_flush_denormal(oc_float x) { return fabsf(x) < 1.0e-20f ? 0.0f : x; }

#ifdef __cplusplus
}
#endif
#endif
