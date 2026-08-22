/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write/pull are render-callback safe:
 no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#include "OpenConnctDSP/oc_ring_buffer.h"
#include "oc_internal.h"

int oc_ring_buffer_init(oc_ring_buffer *ring, oc_float *storage, uint32_t capacity_power_of_two)
{
    if (ring == 0 || storage == 0 || !oc_is_power_of_two(capacity_power_of_two) || capacity_power_of_two < 2u) {
        return 0;
    }

    ring->storage = storage;
    ring->capacity = capacity_power_of_two;
    ring->mask = capacity_power_of_two - 1u;
    oc_store_relaxed(&ring->read_index, 0u);
    oc_store_relaxed(&ring->write_index, 0u);

    return 1;
}

uint32_t oc_ring_buffer_available_read(const oc_ring_buffer *ring)
{
    return oc_load_acquire(&ring->write_index) - oc_load_acquire(&ring->read_index);
}

uint32_t oc_ring_buffer_available_write(const oc_ring_buffer *ring)
{
    return ring->capacity - oc_ring_buffer_available_read(ring);
}

uint32_t oc_ring_buffer_fill_level(const oc_ring_buffer *ring)
{
    return oc_ring_buffer_available_read(ring);
}

uint32_t oc_ring_buffer_write(oc_ring_buffer *ring, const oc_float *src, uint32_t n)
{
    uint32_t read_index = oc_load_acquire(&ring->read_index);
    uint32_t write_index = oc_load_relaxed(&ring->write_index);
    uint32_t writable = ring->capacity - (write_index - read_index);

    if (n > writable) {
        n = writable;
    }

    for (uint32_t i = 0; i < n; ++i) {
        ring->storage[(write_index + i) & ring->mask] = src[i];
    }

    oc_store_release(&ring->write_index, write_index + n);
    return n;
}

uint32_t oc_ring_buffer_read(oc_ring_buffer *ring, oc_float *dst, uint32_t n)
{
    uint32_t write_index = oc_load_acquire(&ring->write_index);
    uint32_t read_index = oc_load_relaxed(&ring->read_index);
    uint32_t readable = write_index - read_index;

    if (n > readable) {
        n = readable;
    }

    for (uint32_t i = 0; i < n; ++i) {
        dst[i] = ring->storage[(read_index + i) & ring->mask];
    }

    oc_store_release(&ring->read_index, read_index + n);
    return n;
}
