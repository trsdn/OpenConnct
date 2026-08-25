/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
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

/* Below this the difference is meaningless and the reading is just the log of a
   denormal, so the probe's running maximum starts here rather than at minus
   infinity. */
#define OC_NOISE_PROBE_FLOOR_DB -120.0f

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
    /* Set by whichever process function ran last. Only the gain-reduction
       readers consult it; see the note on them in the .cpp. */
    int muted;
    /* Noise-floor probe. A second copy of the gate's side-chain, fed the same
       sample the gate is fed, running only while someone is measuring. It is
       not the gate's own detector because the gate is usually switched off at
       the moment a threshold is being chosen for it, and a switched-off gate
       detects nothing. */
    oc_gate_detector noise_probe;
    int noise_probe_armed;
    oc_float noise_probe_max_db;
} oc_channel_strip;

void oc_channel_strip_init(oc_channel_strip *s, oc_sample_rate sr);
void oc_channel_strip_set_pad_db(oc_channel_strip *s, oc_float db);
void oc_channel_strip_set_gain_db(oc_channel_strip *s, oc_float db);
void oc_channel_strip_set_hpf(oc_channel_strip *s, oc_hpf_mode mode, oc_float frequency);
void oc_channel_strip_set_bypasses(oc_channel_strip *s, int gate, int compressor, int exciter, int bass_enhancer);
void oc_channel_strip_process(oc_channel_strip *s, const oc_float *in, oc_float *out, uint32_t n_frames);
/* The channel is muted, so nothing it produces can be heard. Advances only the
   state that has to stay truthful and skips the rest. Takes no output buffer,
   because there is deliberately nothing to write. */
void oc_channel_strip_process_muted(oc_channel_strip *s, const oc_float *in, uint32_t n_frames);
oc_meter_values oc_channel_strip_input_meter(const oc_channel_strip *s);
oc_meter_values oc_channel_strip_output_meter(const oc_channel_strip *s);
oc_float oc_channel_strip_gate_gr_db(const oc_channel_strip *s);
oc_float oc_channel_strip_comp_gr_db(const oc_channel_strip *s);
/* Measure the room in the frame the gate threshold is expressed in.
   Arming resets the detector and the running maximum. */
void oc_channel_strip_arm_noise_probe(oc_channel_strip *s, int armed);
/* Loudest the probe's envelope reached since the last call, then starts again.
   Reading the envelope instantaneously instead would under-report: it falls by
   25 ms per time constant, so a poll every 50 ms would keep missing what the
   gate would have opened on. */
oc_float oc_channel_strip_read_noise_probe_db(oc_channel_strip *s);
#ifdef __cplusplus
}
#endif
#endif
