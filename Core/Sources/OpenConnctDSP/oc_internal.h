/*
 OpenConnctDSP realtime core. Setup/init/configuration functions are for non-render threads.
 Functions named process/next/read/write are render-callback safe: no heap allocation, locks, exceptions, RTTI, I/O, logging, or unbounded loops.
 All storage is caller-owned or fixed-size in POD structs.
*/
#ifndef OC_INTERNAL_H
#define OC_INTERNAL_H
#include "OpenConnctDSP/oc_types.h"
#include <math.h>
#include <stdint.h>

static inline oc_float oc_coeff_for_ms(oc_sample_rate sr, oc_float ms)
{
    if (ms <= 0.0f) {
        return 0.0f;
    }

    return expf(-1.0f / (oc_float)(0.001 * ms * sr));
}

static inline oc_float oc_slew(oc_float current, oc_float target, oc_float coeff)
{
    return target + coeff * (current - target);
}

static inline oc_float oc_clamp_freq(oc_sample_rate sr, oc_float freq)
{
    return oc_clampf(freq, 1.0f, (oc_float)sr * 0.49f);
}

static inline uint32_t oc_load_acquire(const volatile uint32_t *ptr)
{
    return __atomic_load_n(ptr, __ATOMIC_ACQUIRE);
}

static inline uint32_t oc_load_relaxed(const volatile uint32_t *ptr)
{
    return __atomic_load_n(ptr, __ATOMIC_RELAXED);
}

static inline void oc_store_release(volatile uint32_t *ptr, uint32_t value)
{
    __atomic_store_n(ptr, value, __ATOMIC_RELEASE);
}

static inline void oc_store_relaxed(volatile uint32_t *ptr, uint32_t value)
{
    __atomic_store_n(ptr, value, __ATOMIC_RELAXED);
}

static inline int oc_is_power_of_two(uint32_t value)
{
    return value != 0u && (value & (value - 1u)) == 0u;
}

#endif
