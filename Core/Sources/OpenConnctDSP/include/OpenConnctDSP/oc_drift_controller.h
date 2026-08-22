/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_DRIFT_CONTROLLER_H
#define OC_DRIFT_CONTROLLER_H
#include "oc_types.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct oc_drift_controller {
    oc_float target_fill, kp, ki, integrator, integrator_limit, ratio_limit, slew_per_update;
    oc_float current_ratio, error;
} oc_drift_controller;
void oc_drift_controller_init(oc_drift_controller *d, oc_float target_fill, oc_float kp, oc_float ki, oc_float integrator_limit, oc_float ratio_limit, oc_float slew_per_update);
oc_float oc_drift_controller_update(oc_drift_controller *d, oc_float fill_level);
oc_float oc_drift_controller_current_ratio(const oc_drift_controller *d);
oc_float oc_drift_controller_current_error(const oc_drift_controller *d);
#ifdef __cplusplus
}
#endif
#endif
