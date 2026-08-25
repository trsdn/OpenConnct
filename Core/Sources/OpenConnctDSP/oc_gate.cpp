/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnctDSP/oc_gate.h"
#include "oc_internal.h"

void oc_gate_detector_init(oc_gate_detector *det, oc_sample_rate sr)
{
    oc_biquad_init_identity(&det->key_hp);
    oc_biquad_set_highpass(&det->key_hp, sr, OC_GATE_KEY_HP_HZ, 0.707f);
    det->attack_coeff = oc_coeff_for_ms(sr, OC_GATE_DETECTOR_ATTACK_MS);
    det->release_coeff = oc_coeff_for_ms(sr, OC_GATE_DETECTOR_RELEASE_MS);
    det->env = 0.0f;
}

void oc_gate_detector_reset(oc_gate_detector *det)
{
    oc_biquad_reset(&det->key_hp);
    det->env = 0.0f;
}

/* High-passed, rectified, envelope-followed. Driving a gate from the raw sample
   magnitude instead made a single noise peak reopen it, and made |x| collapse at
   every zero crossing. */
oc_float oc_gate_detector_process_sample(oc_gate_detector *det, oc_float x)
{
    oc_float key = oc_biquad_process_sample(&det->key_hp, x);
    oc_float rectified = fabsf(key);
    oc_float coeff = rectified > det->env ? det->attack_coeff : det->release_coeff;
    det->env = oc_slew(det->env, rectified, coeff);
    return oc_linear_to_db(det->env);
}

void oc_gate_init(oc_gate *gate, oc_sample_rate sr)
{
    gate->sr = sr;
    gate->gain = 0.0f;
    gate->gain_reduction_db = -120.0f;
    gate->state = OC_GATE_CLOSED;
    oc_gate_detector_init(&gate->det, sr);
    oc_gate_configure(gate, -50.0f, 5.0f, 20.0f, 80.0f, 3.0f, -120.0f);
}

void oc_gate_configure(
    oc_gate *gate,
    oc_float threshold_db,
    oc_float attack_ms,
    oc_float hold_ms,
    oc_float release_ms,
    oc_float hysteresis_db,
    oc_float range_db)
{
    gate->threshold_db = threshold_db;
    gate->close_threshold_db = threshold_db - fabsf(hysteresis_db);
    gate->attack_ms = attack_ms;
    gate->hold_ms = hold_ms;
    gate->release_ms = release_ms;
    gate->attack_coeff = oc_coeff_for_ms(gate->sr, attack_ms);
    gate->release_coeff = oc_coeff_for_ms(gate->sr, release_ms);
    gate->hold_samples = (uint32_t)(gate->sr * hold_ms * 0.001);
    gate->hold_remaining = 0;
    /* Below -80 dB the difference is inaudible, so that end of the range is
       treated as a full mute and the closed gate reaches exact zero. */
    gate->range_db = oc_clampf(range_db, -120.0f, 0.0f);
    gate->range_gain = gate->range_db <= -80.0f ? 0.0f : oc_db_to_linear(gate->range_db);

    if (gate->state == OC_GATE_CLOSED) {
        gate->gain = gate->range_gain;
    }
}

oc_float oc_gate_process_sample(oc_gate *gate, oc_float input)
{
    oc_float input_db = oc_gate_detector_process_sample(&gate->det, input);

    switch (gate->state) {
    case OC_GATE_CLOSED:
        if (input_db >= gate->threshold_db) {
            gate->state = OC_GATE_ATTACKING;
        }
        break;
    case OC_GATE_ATTACKING:
        if (input_db < gate->close_threshold_db) {
            gate->state = OC_GATE_RELEASING;
        } else if (gate->gain > 0.99f) {
            gate->gain = 1.0f;
            gate->state = OC_GATE_OPEN;
        }
        break;
    case OC_GATE_OPEN:
        if (input_db < gate->close_threshold_db) {
            gate->state = OC_GATE_HOLDING;
            gate->hold_remaining = gate->hold_samples;
        }
        break;
    case OC_GATE_HOLDING:
        if (input_db >= gate->threshold_db) {
            gate->state = OC_GATE_OPEN;
        } else if (gate->hold_remaining > 0) {
            --gate->hold_remaining;
        } else {
            gate->state = OC_GATE_RELEASING;
        }
        break;
    case OC_GATE_RELEASING:
        if (input_db >= gate->threshold_db) {
            gate->state = OC_GATE_ATTACKING;
        } else if (gate->gain <= gate->range_gain + 1.0e-6f) {
            gate->gain = gate->range_gain;
            gate->state = OC_GATE_CLOSED;
        }
        break;
    }

    oc_float target = gate->range_gain;

    if (gate->state == OC_GATE_ATTACKING || gate->state == OC_GATE_OPEN || gate->state == OC_GATE_HOLDING) {
        target = 1.0f;
    }

    oc_float coeff = target > gate->gain ? gate->attack_coeff : gate->release_coeff;
    gate->gain = oc_slew(gate->gain, target, coeff);

    if (target == 1.0f && gate->gain > 0.999f) {
        gate->gain = 1.0f;
    }

    if (target == gate->range_gain && gate->gain <= gate->range_gain + 1.0e-6f) {
        gate->gain = gate->range_gain;
    }

    gate->gain_reduction_db = oc_linear_to_db(fmaxf(gate->gain, 1.0e-6f));
    return input * gate->gain;
}

void oc_gate_process_block(oc_gate *gate, const oc_float *in, oc_float *out, uint32_t n)
{
    for (uint32_t i = 0; i < n; ++i) {
        out[i] = oc_gate_process_sample(gate, in[i]);
    }
}

oc_float oc_gate_gain_reduction_db(const oc_gate *gate)
{
    return gate->gain_reduction_db;
}

oc_float oc_gate_detector_db(const oc_gate *gate)
{
    return oc_linear_to_db(gate->det.env);
}

oc_gate_state oc_gate_current_state(const oc_gate *gate)
{
    return gate->state;
}
