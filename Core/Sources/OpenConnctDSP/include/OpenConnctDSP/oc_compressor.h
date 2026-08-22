/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_COMPRESSOR_H
#define OC_COMPRESSOR_H
#include "oc_types.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef enum oc_detector_mode { OC_DETECTOR_PEAK=0, OC_DETECTOR_RMS=1 } oc_detector_mode;

typedef struct oc_compressor {
    oc_sample_rate sr;
    oc_float threshold_db, ratio, attack_ms, release_ms, makeup_db, knee_db;
    oc_detector_mode detector;
    oc_float env, rms_sq, gain, gain_reduction_db;
    oc_float attack_coeff, release_coeff;
} oc_compressor;

void oc_compressor_init(oc_compressor *c, oc_sample_rate sr);
void oc_compressor_configure(oc_compressor *c, oc_float threshold_db, oc_float ratio, oc_float attack_ms, oc_float release_ms, oc_float makeup_db, oc_float knee_db, oc_detector_mode detector);
oc_float oc_compressor_gain_db_for_level(const oc_compressor *c, oc_float input_db);
oc_float oc_compressor_process_sample(oc_compressor *c, oc_float x);
void oc_compressor_process_block(oc_compressor *c, const oc_float *in, oc_float *out, uint32_t n);
oc_float oc_compressor_gain_reduction_db(const oc_compressor *c);

#ifdef __cplusplus
}
#endif
#endif
