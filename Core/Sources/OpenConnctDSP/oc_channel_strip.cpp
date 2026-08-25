/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnctDSP/oc_channel_strip.h"
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
    strip->bypass_bass_enhancer = 1;

    oc_gate_init(&strip->gate, sr);
    oc_compressor_init(&strip->compressor, sr);
    oc_exciter_init(&strip->exciter, sr);
    oc_bass_enhancer_init(&strip->bass_enhancer, sr);
    oc_meter_init(&strip->input_meter, sr, 300.0f);
    oc_meter_init(&strip->output_meter, sr, 300.0f);
    strip->muted = 0;
    oc_gate_detector_init(&strip->noise_probe, sr);
    strip->noise_probe_armed = 0;
    strip->noise_probe_max_db = OC_NOISE_PROBE_FLOOR_DB;
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
    int bass_enhancer)
{
    strip->bypass_gate = gate;
    strip->bypass_compressor = compressor;
    strip->bypass_exciter = exciter;
    strip->bypass_bass_enhancer = bass_enhancer;
}

void oc_channel_strip_process(oc_channel_strip *strip, const oc_float *in, oc_float *out, uint32_t n_frames)
{
    strip->muted = 0;
    oc_meter_process_block(&strip->input_meter, in, n_frames);

    int all_bypassed = strip->hpf_mode == OC_HPF_OFF
        && strip->bypass_gate
        && strip->bypass_compressor
        && strip->bypass_exciter
        && strip->bypass_bass_enhancer;

    // The probe has to see the same sample the gate would, so it cannot be fed
    // from a vectorised shortcut that never visits a sample individually. It is
    // armed only while someone is actively measuring, so the shortcut is still
    // there the rest of the time.
    if (all_bypassed
        && !strip->noise_probe_armed
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

        // Exactly here: after pad, gain and the high-pass, before the gate.
        // This is the gate's input, which is the only place a measurement of a
        // room can be compared against a gate threshold.
        if (strip->noise_probe_armed) {
            oc_float probe_db = oc_gate_detector_process_sample(&strip->noise_probe, sample);
            if (probe_db > strip->noise_probe_max_db) strip->noise_probe_max_db = probe_db;
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

        if (!strip->bypass_bass_enhancer) {
            sample = oc_bass_enhancer_process_sample(&strip->bass_enhancer, sample);
        }

        out[i] = sample;
    }

    oc_meter_process_block(&strip->output_meter, out, n_frames);
}

// A muted channel is summed into the mix at a gain of exactly zero, so every
// stage after the input meter is arithmetic whose result is discarded. This
// runs the parts that would otherwise start lying, and nothing else.
//
// What is deliberately still done elsewhere, and must stay that way: the caller
// keeps draining this channel's ring buffer and keeps its drift controller
// running. Muting is not a reason to stop consuming from a device that is still
// producing -- the ring would fill, the controller would wind up against a
// saturated error, and unmuting would hand you a backlog rather than the
// present. That is the trap in "skip muted channels", and it is why this
// function takes an input block at all.
//
// What is done here:
//  - The input meter, because it is measured before pad, gain, fader and mute,
//    and is what the level display and the gain calibration read. A device
//    OpenConnct has never seen arrives muted, so this is exactly when someone
//    wants to see whether it is picking anything up.
//  - The pad and gain smoothers, advanced a block at a time rather than a
//    sample at a time, so a gain changed during the mute is already in position
//    when the channel comes back rather than sliding into place afterwards.
//  - The output meter, decayed towards silence, because a meter that is simply
//    not called freezes at its last reading and leaves it on screen.
//
// What is deliberately not done: the filters, the gate, the compressor, the
// exciter and the bass enhancer keep whatever internal state they had. Resuming
// with stale state would ordinarily risk a click, but the caller ramps the
// fader up from zero across the first block after unmuting, which is precisely
// where that discontinuity lands -- so it is attenuated by the ramp that is
// already there for the mute itself.
void oc_channel_strip_process_muted(oc_channel_strip *strip, const oc_float *in, uint32_t n_frames)
{
    strip->muted = 1;
    oc_meter_process_block(&strip->input_meter, in, n_frames);
    oc_smoothed_param_advance(&strip->pad_gain, n_frames);
    oc_smoothed_param_advance(&strip->gain, n_frames);
    oc_meter_process_silence(&strip->output_meter, n_frames);
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
//
// A muted channel is the same problem arriving by a different route: the stage
// is no longer being run, so its last value would sit frozen on the meter for
// as long as the mute lasts.
oc_float oc_channel_strip_gate_gr_db(const oc_channel_strip *strip)
{
    if (strip->bypass_gate || strip->muted) return 0.0f;
    return oc_gate_gain_reduction_db(&strip->gate);
}

oc_float oc_channel_strip_comp_gr_db(const oc_channel_strip *strip)
{
    if (strip->bypass_compressor || strip->muted) return 0.0f;
    return oc_compressor_gain_reduction_db(&strip->compressor);
}

void oc_channel_strip_arm_noise_probe(oc_channel_strip *strip, int armed)
{
    oc_gate_detector_reset(&strip->noise_probe);
    strip->noise_probe_max_db = OC_NOISE_PROBE_FLOOR_DB;
    strip->noise_probe_armed = armed;
}

// Read and restart. The reader is not the render thread, so the reset can in
// principle land between the render thread's compare and its store and drop one
// block's maximum. The cost of that is one lost reading out of the forty a
// measurement collects, and the alternative -- a second buffer and a sequence
// counter -- would be a lot of machinery to protect a number that is about to
// have a percentile taken of it anyway.
oc_float oc_channel_strip_read_noise_probe_db(oc_channel_strip *strip)
{
    oc_float value = strip->noise_probe_max_db;
    strip->noise_probe_max_db = OC_NOISE_PROBE_FLOOR_DB;
    return value;
}
