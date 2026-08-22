/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_PARAM_QUEUE_H
#define OC_PARAM_QUEUE_H
#include "oc_types.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct oc_param_event { uint32_t param_id; oc_float value; } oc_param_event;
typedef struct oc_param_queue {
    oc_param_event *storage;
    uint32_t capacity, mask;
    volatile uint32_t read_index, write_index, dropped;
} oc_param_queue;
int oc_param_queue_init(oc_param_queue *q, oc_param_event *storage, uint32_t capacity_power_of_two);
int oc_param_queue_push(oc_param_queue *q, uint32_t param_id, oc_float value);
int oc_param_queue_pop(oc_param_queue *q, oc_param_event *out_event);
uint32_t oc_param_queue_dropped_count(const oc_param_queue *q);
uint32_t oc_param_queue_available_read(const oc_param_queue *q);
#ifdef __cplusplus
}
#endif
#endif
