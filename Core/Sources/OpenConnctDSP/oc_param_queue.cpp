/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnctDSP/oc_param_queue.h"
#include "oc_internal.h"

int oc_param_queue_init(oc_param_queue *queue, oc_param_event *storage, uint32_t capacity_power_of_two)
{
    if (queue == 0 || storage == 0 || !oc_is_power_of_two(capacity_power_of_two) || capacity_power_of_two < 2u) {
        return 0;
    }

    queue->storage = storage;
    queue->capacity = capacity_power_of_two;
    queue->mask = capacity_power_of_two - 1u;
    oc_store_relaxed(&queue->read_index, 0u);
    oc_store_relaxed(&queue->write_index, 0u);
    oc_store_relaxed(&queue->dropped, 0u);

    return 1;
}

int oc_param_queue_push(oc_param_queue *queue, uint32_t param_id, oc_float value)
{
    uint32_t read_index = oc_load_acquire(&queue->read_index);
    uint32_t write_index = oc_load_relaxed(&queue->write_index);

    if (write_index - read_index >= queue->capacity) {
        __atomic_add_fetch(&queue->dropped, 1u, __ATOMIC_RELAXED);
        return 0;
    }

    queue->storage[write_index & queue->mask].param_id = param_id;
    queue->storage[write_index & queue->mask].value = value;
    oc_store_release(&queue->write_index, write_index + 1u);

    return 1;
}

int oc_param_queue_pop(oc_param_queue *queue, oc_param_event *out_event)
{
    uint32_t write_index = oc_load_acquire(&queue->write_index);
    uint32_t read_index = oc_load_relaxed(&queue->read_index);

    if (write_index == read_index) {
        return 0;
    }

    *out_event = queue->storage[read_index & queue->mask];
    oc_store_release(&queue->read_index, read_index + 1u);

    return 1;
}

uint32_t oc_param_queue_dropped_count(const oc_param_queue *queue)
{
    return oc_load_acquire(&queue->dropped);
}

uint32_t oc_param_queue_available_read(const oc_param_queue *queue)
{
    return oc_load_acquire(&queue->write_index) - oc_load_acquire(&queue->read_index);
}
