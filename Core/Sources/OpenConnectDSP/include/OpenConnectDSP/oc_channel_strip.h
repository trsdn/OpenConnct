/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_CHANNEL_STRIP_H
#define OC_CHANNEL_STRIP_H
#include "oc_smoothed_param.h"
#include "oc_biquad.h"
#include "oc_gate.h"
#include "oc_compressor.h"
#include "oc_exciter.h"
#include "oc_bass_enhancer.h"
#include "oc_meter.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef enum oc_hpf_mode { OC_HPF_OFF=0, OC_HPF_75=1, OC_HPF_150=2, OC_HPF_CONTINUOUS=3 } oc_hpf_mode;

typedef struct oc_channel_strip {
    oc_sample_rate sr;
    oc_smoothed_param pad_gain, gain;
    oc_hpf_mode hpf_mode;
    oc_float hpf_freq;
    int bypass_gate, bypass_compressor, bypass_exciter, bypass_bass_enhancer;
    oc_biquad_cascade2 hpf;
    oc_gate gate;
    oc_compressor compressor;
    oc_exciter exciter;
    oc_bass_enhancer bass_enhancer;
    oc_meter input_meter, output_meter;
} oc_channel_strip;

void oc_channel_strip_init(oc_channel_strip *s, oc_sample_rate sr);
void oc_channel_strip_set_pad_db(oc_channel_strip *s, oc_float db);
void oc_channel_strip_set_gain_db(oc_channel_strip *s, oc_float db);
void oc_channel_strip_set_hpf(oc_channel_strip *s, oc_hpf_mode mode, oc_float frequency);
void oc_channel_strip_set_bypasses(oc_channel_strip *s, int gate, int compressor, int exciter, int bass_enhancer);
void oc_channel_strip_process(oc_channel_strip *s, const oc_float *in, oc_float *out, uint32_t n_frames);
oc_meter_values oc_channel_strip_input_meter(const oc_channel_strip *s);
oc_meter_values oc_channel_strip_output_meter(const oc_channel_strip *s);
oc_float oc_channel_strip_gate_gr_db(const oc_channel_strip *s);
oc_float oc_channel_strip_comp_gr_db(const oc_channel_strip *s);
#ifdef __cplusplus
}
#endif
#endif
