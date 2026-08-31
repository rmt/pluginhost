#ifndef PLUGINHOST_RT_ATOMIC_H
#define PLUGINHOST_RT_ATOMIC_H

#include <stdint.h>
#include <stdatomic.h>

/*
 * Fixed-width lock-free atomics used by generated callback code. The Nim
 * standard-library wrappers install trace frames under the shared product
 * profile, so callback code calls these C11 operations directly instead.
 */
typedef _Atomic(uint32_t) pluginhost_rt_atomic_u32;
typedef _Atomic(int32_t) pluginhost_rt_atomic_i32;
typedef _Atomic(uint64_t) pluginhost_rt_atomic_u64;

_Static_assert(sizeof(pluginhost_rt_atomic_u32) == sizeof(uint32_t),
               "unexpected 32-bit atomic size");
_Static_assert(_Alignof(pluginhost_rt_atomic_u32) == _Alignof(uint32_t),
               "unexpected 32-bit atomic alignment");
_Static_assert(sizeof(pluginhost_rt_atomic_i32) == sizeof(int32_t),
               "unexpected signed 32-bit atomic size");
_Static_assert(_Alignof(pluginhost_rt_atomic_i32) == _Alignof(int32_t),
               "unexpected signed 32-bit atomic alignment");
_Static_assert(sizeof(pluginhost_rt_atomic_u64) == sizeof(uint64_t),
               "unexpected 64-bit atomic size");
_Static_assert(_Alignof(pluginhost_rt_atomic_u64) == _Alignof(uint64_t),
               "unexpected 64-bit atomic alignment");
_Static_assert(__atomic_always_lock_free(sizeof(uint32_t), 0),
               "pluginhost requires lock-free 32-bit atomics");
_Static_assert(__atomic_always_lock_free(sizeof(uint64_t), 0),
               "pluginhost requires lock-free 64-bit atomics");

static inline uint32_t
pluginhost_rt_atomic_u32_load_relaxed(const pluginhost_rt_atomic_u32 *value) {
    return atomic_load_explicit(value, memory_order_relaxed);
}

static inline uint32_t
pluginhost_rt_atomic_u32_load_acquire(const pluginhost_rt_atomic_u32 *value) {
    return atomic_load_explicit(value, memory_order_acquire);
}

static inline void
pluginhost_rt_atomic_u32_store_relaxed(pluginhost_rt_atomic_u32 *value,
                                        uint32_t desired) {
    atomic_store_explicit(value, desired, memory_order_relaxed);
}

static inline void
pluginhost_rt_atomic_u32_store_release(pluginhost_rt_atomic_u32 *value,
                                        uint32_t desired) {
    atomic_store_explicit(value, desired, memory_order_release);
}

static inline uint32_t
pluginhost_rt_atomic_u32_fetch_add_relaxed(pluginhost_rt_atomic_u32 *value,
                                            uint32_t amount) {
    return atomic_fetch_add_explicit(value, amount, memory_order_relaxed);
}

static inline uint32_t
pluginhost_rt_atomic_u32_fetch_add_acquire(pluginhost_rt_atomic_u32 *value,
                                            uint32_t amount) {
    return atomic_fetch_add_explicit(value, amount, memory_order_acquire);
}

static inline uint32_t
pluginhost_rt_atomic_u32_fetch_sub_release(pluginhost_rt_atomic_u32 *value,
                                            uint32_t amount) {
    return atomic_fetch_sub_explicit(value, amount, memory_order_release);
}

static inline uint32_t
pluginhost_rt_atomic_u32_fetch_or_relaxed(pluginhost_rt_atomic_u32 *value,
                                           uint32_t bits) {
    return atomic_fetch_or_explicit(value, bits, memory_order_relaxed);
}

static inline uint32_t
pluginhost_rt_atomic_u32_exchange_acquire(pluginhost_rt_atomic_u32 *value,
                                           uint32_t desired) {
    return atomic_exchange_explicit(value, desired, memory_order_acquire);
}

static inline int
pluginhost_rt_atomic_u32_compare_exchange_relaxed(
        pluginhost_rt_atomic_u32 *value, uint32_t *expected,
        uint32_t desired) {
    return atomic_compare_exchange_strong_explicit(
        value, expected, desired, memory_order_relaxed, memory_order_relaxed);
}

static inline int
pluginhost_rt_atomic_u32_compare_exchange_acquire(
        pluginhost_rt_atomic_u32 *value, uint32_t *expected,
        uint32_t desired) {
    return atomic_compare_exchange_strong_explicit(
        value, expected, desired, memory_order_acquire, memory_order_relaxed);
}

static inline int32_t
pluginhost_rt_atomic_i32_load_acquire(const pluginhost_rt_atomic_i32 *value) {
    return atomic_load_explicit(value, memory_order_acquire);
}

static inline void
pluginhost_rt_atomic_i32_store_relaxed(pluginhost_rt_atomic_i32 *value,
                                        int32_t desired) {
    atomic_store_explicit(value, desired, memory_order_relaxed);
}

static inline uint64_t
pluginhost_rt_atomic_u64_load_relaxed(const pluginhost_rt_atomic_u64 *value) {
    return atomic_load_explicit(value, memory_order_relaxed);
}

static inline uint64_t
pluginhost_rt_atomic_u64_load_acquire(const pluginhost_rt_atomic_u64 *value) {
    return atomic_load_explicit(value, memory_order_acquire);
}

static inline void
pluginhost_rt_atomic_u64_store_relaxed(pluginhost_rt_atomic_u64 *value,
                                        uint64_t desired) {
    atomic_store_explicit(value, desired, memory_order_relaxed);
}

static inline void
pluginhost_rt_atomic_u64_store_release(pluginhost_rt_atomic_u64 *value,
                                        uint64_t desired) {
    atomic_store_explicit(value, desired, memory_order_release);
}

static inline uint64_t
pluginhost_rt_atomic_u64_fetch_add_relaxed(pluginhost_rt_atomic_u64 *value,
                                            uint64_t amount) {
    return atomic_fetch_add_explicit(value, amount, memory_order_relaxed);
}

static inline uint64_t
pluginhost_rt_atomic_u64_fetch_add_release(pluginhost_rt_atomic_u64 *value,
                                            uint64_t amount) {
    return atomic_fetch_add_explicit(value, amount, memory_order_release);
}

static inline uint64_t
pluginhost_rt_atomic_u64_exchange_acquire(pluginhost_rt_atomic_u64 *value,
                                           uint64_t desired) {
    return atomic_exchange_explicit(value, desired, memory_order_acquire);
}

static inline int
pluginhost_rt_atomic_u64_compare_exchange_relaxed(
        pluginhost_rt_atomic_u64 *value, uint64_t *expected,
        uint64_t desired) {
    return atomic_compare_exchange_strong_explicit(
        value, expected, desired, memory_order_relaxed, memory_order_relaxed);
}

#endif
