/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_RING_BUFFER_H
#define OC_RING_BUFFER_H
#include "oc_types.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct oc_ring_buffer {
    oc_float *storage;
    uint32_t capacity;
    uint32_t mask;
    volatile uint32_t read_index;
    volatile uint32_t write_index;
} oc_ring_buffer;
int oc_ring_buffer_init(oc_ring_buffer *rb, oc_float *storage, uint32_t capacity_power_of_two);
uint32_t oc_ring_buffer_available_read(const oc_ring_buffer *rb);
uint32_t oc_ring_buffer_available_write(const oc_ring_buffer *rb);
uint32_t oc_ring_buffer_fill_level(const oc_ring_buffer *rb);
uint32_t oc_ring_buffer_write(oc_ring_buffer *rb, const oc_float *src, uint32_t n);
uint32_t oc_ring_buffer_read(oc_ring_buffer *rb, oc_float *dst, uint32_t n);
#ifdef __cplusplus
}
#endif
#endif
