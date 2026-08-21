/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_GATE_H
#define OC_GATE_H
#include "oc_biquad.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef enum oc_gate_state { OC_GATE_CLOSED=0, OC_GATE_ATTACKING=1, OC_GATE_OPEN=2, OC_GATE_HOLDING=3, OC_GATE_RELEASING=4 } oc_gate_state;

/* Side-chain ("key") high-pass. Rumble below this is inaudible but its peaks are
   large enough to hold a gate open forever, so the detector must not see it. */
#define OC_GATE_KEY_HP_HZ 120.0f
/* Detector envelope. Fast enough to catch a syllable onset, slow enough that the
   detector tracks the signal envelope instead of individual sample peaks. */
#define OC_GATE_DETECTOR_ATTACK_MS 1.0f
#define OC_GATE_DETECTOR_RELEASE_MS 25.0f

typedef struct oc_gate {
    oc_sample_rate sr;
    oc_float threshold_db, close_threshold_db;
    oc_float attack_ms, hold_ms, release_ms;
    oc_float range_db, range_gain;
    oc_float gain, gain_reduction_db;
    oc_gate_state state;
    uint32_t hold_remaining, hold_samples;
    oc_float attack_coeff, release_coeff;
    oc_biquad key_hp;
    oc_float env;
    oc_float detector_attack_coeff, detector_release_coeff;
} oc_gate;

void oc_gate_init(oc_gate *g, oc_sample_rate sr);
void oc_gate_configure(oc_gate *g, oc_float threshold_db, oc_float attack_ms, oc_float hold_ms, oc_float release_ms, oc_float hysteresis_db, oc_float range_db);
oc_float oc_gate_process_sample(oc_gate *g, oc_float x);
void oc_gate_process_block(oc_gate *g, const oc_float *in, oc_float *out, uint32_t n);
oc_float oc_gate_gain_reduction_db(const oc_gate *g);
oc_float oc_gate_detector_db(const oc_gate *g);
oc_gate_state oc_gate_current_state(const oc_gate *g);

#ifdef __cplusplus
}
#endif
#endif
