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
    controller->integrator += controller->ki * controller->error;
    controller->integrator = oc_clampf(
        controller->integrator,
        -controller->integrator_limit,
        controller->integrator_limit);

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
