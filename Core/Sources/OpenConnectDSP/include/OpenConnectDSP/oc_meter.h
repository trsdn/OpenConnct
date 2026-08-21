/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_METER_H
#define OC_METER_H
#include "oc_types.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct oc_meter_values { oc_float peak; oc_float rms; oc_float peak_db; oc_float rms_db; } oc_meter_values;
typedef struct oc_meter { oc_sample_rate sr; oc_float decay_coeff; oc_float peak; oc_float rms_sq; } oc_meter;
void oc_meter_init(oc_meter *m, oc_sample_rate sr, oc_float decay_ms);
void oc_meter_reset(oc_meter *m);
void oc_meter_process_block(oc_meter *m, const oc_float *in, uint32_t n);
oc_meter_values oc_meter_read(const oc_meter *m);
#ifdef __cplusplus
}
#endif
#endif
