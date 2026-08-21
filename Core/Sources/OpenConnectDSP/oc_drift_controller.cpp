/*
 OpenConnectDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnectDSP/oc_drift_controller.h"
#include "oc_internal.h"

void oc_drift_controller_init(
    oc_drift_controller *controller,
    oc_float target_fill,
    oc_float kp,
    oc_float ki,
    oc_float integrator_limit,
    oc_float ratio_limit,
    oc_float slew_per_update)
{
    controller->target_fill = target_fill;
    controller->kp = kp;
    controller->ki = ki;
    controller->integrator = 0.0f;
    controller->integrator_limit = fabsf(integrator_limit);
    controller->ratio_limit = fabsf(ratio_limit);
    controller->slew_per_update = fabsf(slew_per_update);
    controller->current_ratio = 1.0f;
    controller->error = 0.0f;
}

oc_float oc_drift_controller_update(oc_drift_controller *controller, oc_float fill_level)
{
    controller->error = fill_level - controller->target_fill;

    /* Conditional integration.
     *
     * The fill level is itself an integral of the rate error, so a plain PI
     * loop is second order and will ring unless it is damped. Worse, a step
     * disturbance -- a scheduling hiccup where one side of the ring runs a
     * cycle without the other, which real hardware does every few minutes --
     * drives the integrator to its limit within a couple of seconds. It then
     * has to unwind from saturation *after* the error has already crossed
     * zero, which is what pushes the fill past the target and out the other
     * side.
     *
     * Integrating only while the proportional-plus-integral output is inside
     * its limit, or while the error is pushing the output back towards the
     * middle, removes the windup without touching steady-state accuracy: in
     * normal operation the output is nowhere near the limit and this is a
     * no-op. */
    oc_float unlimited = controller->kp * controller->error + controller->integrator;
    int saturated_high = unlimited >= controller->ratio_limit;
    int saturated_low = unlimited <= -controller->ratio_limit;
    int winding_up =
        (saturated_high && controller->error > 0.0f) ||
        (saturated_low && controller->error < 0.0f);

    if (!winding_up) {
        controller->integrator += controller->ki * controller->error;
        controller->integrator = oc_clampf(
            controller->integrator,
            -controller->integrator_limit,
            controller->integrator_limit);
    }

    oc_float offset = controller->kp * controller->error + controller->integrator;
    offset = oc_clampf(offset, -controller->ratio_limit, controller->ratio_limit);

    oc_float desired = 1.0f + offset;
    oc_float delta = desired - controller->current_ratio;
    delta = oc_clampf(delta, -controller->slew_per_update, controller->slew_per_update);

    controller->current_ratio += delta;
    return controller->current_ratio;
}

oc_float oc_drift_controller_current_ratio(const oc_drift_controller *controller)
{
    return controller->current_ratio;
}

oc_float oc_drift_controller_current_error(const oc_drift_controller *controller)
{
    return controller->error;
}
