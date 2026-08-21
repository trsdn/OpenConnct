/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnectDSP/oc_channel_strip.h"
#include <Accelerate/Accelerate.h>

void oc_channel_strip_init(oc_channel_strip *strip, oc_sample_rate sr)
{
    strip->sr = sr;
    oc_smoothed_param_init(&strip->pad_gain, sr, 2.0f, 1.0f);
    oc_smoothed_param_init(&strip->gain, sr, 5.0f, 1.0f);

    strip->hpf_mode = OC_HPF_OFF;
    strip->hpf_freq = 75.0f;
    oc_biquad_cascade2_set_highpass(&strip->hpf, sr, 75.0f);

    strip->bypass_gate = 1;
    strip->bypass_compressor = 1;
    strip->bypass_exciter = 1;
    strip->bypass_big_bottom = 1;

    oc_gate_init(&strip->gate, sr);
    oc_compressor_init(&strip->compressor, sr);
    oc_exciter_init(&strip->exciter, sr);
    oc_big_bottom_init(&strip->big_bottom, sr);
    oc_meter_init(&strip->input_meter, sr, 300.0f);
    oc_meter_init(&strip->output_meter, sr, 300.0f);
}

void oc_channel_strip_set_pad_db(oc_channel_strip *strip, oc_float db)
{
    oc_smoothed_param_set_target(&strip->pad_gain, oc_db_to_linear(db));
}

void oc_channel_strip_set_gain_db(oc_channel_strip *strip, oc_float db)
{
    oc_smoothed_param_set_target(&strip->gain, oc_db_to_linear(db));
}

void oc_channel_strip_set_hpf(oc_channel_strip *strip, oc_hpf_mode mode, oc_float frequency)
{
    strip->hpf_mode = mode;

    if (mode == OC_HPF_75) {
        strip->hpf_freq = 75.0f;
    } else if (mode == OC_HPF_150) {
        strip->hpf_freq = 150.0f;
    } else {
        strip->hpf_freq = frequency;
    }

    if (mode != OC_HPF_OFF) {
        oc_biquad_cascade2_set_highpass(&strip->hpf, strip->sr, strip->hpf_freq);
    }
}

void oc_channel_strip_set_bypasses(
    oc_channel_strip *strip,
    int gate,
    int compressor,
    int exciter,
    int big_bottom)
{
    strip->bypass_gate = gate;
    strip->bypass_compressor = compressor;
    strip->bypass_exciter = exciter;
    strip->bypass_big_bottom = big_bottom;
}

void oc_channel_strip_process(oc_channel_strip *strip, const oc_float *in, oc_float *out, uint32_t n_frames)
{
    oc_meter_process_block(&strip->input_meter, in, n_frames);

    int all_bypassed = strip->hpf_mode == OC_HPF_OFF
        && strip->bypass_gate
        && strip->bypass_compressor
        && strip->bypass_exciter
        && strip->bypass_big_bottom;

    if (all_bypassed
        && oc_smoothed_param_is_settled(&strip->pad_gain)
        && oc_smoothed_param_is_settled(&strip->gain)) {
        oc_float scalar = strip->pad_gain.current * strip->gain.current;
        vDSP_vsmul(in, 1, &scalar, out, 1, n_frames);
        oc_meter_process_block(&strip->output_meter, out, n_frames);
        return;
    }

    for (uint32_t i = 0; i < n_frames; ++i) {
        oc_float sample = in[i];
        sample *= oc_smoothed_param_next(&strip->pad_gain);
        sample *= oc_smoothed_param_next(&strip->gain);

        if (strip->hpf_mode != OC_HPF_OFF) {
            sample = oc_biquad_cascade2_process_sample(&strip->hpf, sample);
        }

        if (!strip->bypass_gate) {
            sample = oc_gate_process_sample(&strip->gate, sample);
        }

        if (!strip->bypass_compressor) {
            sample = oc_compressor_process_sample(&strip->compressor, sample);
        }

        if (!strip->bypass_exciter) {
            sample = oc_exciter_process_sample(&strip->exciter, sample);
        }

        if (!strip->bypass_big_bottom) {
            sample = oc_big_bottom_process_sample(&strip->big_bottom, sample);
        }

        out[i] = sample;
    }

    oc_meter_process_block(&strip->output_meter, out, n_frames);
}

oc_meter_values oc_channel_strip_input_meter(const oc_channel_strip *strip)
{
    return oc_meter_read(&strip->input_meter);
}

oc_meter_values oc_channel_strip_output_meter(const oc_channel_strip *strip)
{
    return oc_meter_read(&strip->output_meter);
}

// A bypassed stage reports no reduction. Without this the stage's last value
// persists -- and an untouched gate initialises to -120 dB (fully closed) --
// so a disabled gate would drive its meter to full deflection.
oc_float oc_channel_strip_gate_gr_db(const oc_channel_strip *strip)
{
    if (strip->bypass_gate) return 0.0f;
    return oc_gate_gain_reduction_db(&strip->gate);
}

oc_float oc_channel_strip_comp_gr_db(const oc_channel_strip *strip)
{
    if (strip->bypass_compressor) return 0.0f;
    return oc_compressor_gain_reduction_db(&strip->compressor);
}
