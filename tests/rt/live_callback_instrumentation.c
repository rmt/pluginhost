#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <jack/jack.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

typedef struct pluginhost_rt_instrumentation_report {
    uint64_t allocations;
    uint64_t deallocations;
    uint64_t locks;
    uint64_t prints;
    uint64_t io;
    uint64_t callback_entries;
} pluginhost_rt_instrumentation_report;
_Static_assert(__atomic_always_lock_free(sizeof(uint32_t), 0),
               "instrumentation requires lock-free 32-bit atomics");
_Static_assert(__atomic_always_lock_free(sizeof(uint64_t), 0),
               "instrumentation requires lock-free 64-bit atomics");

static _Atomic(uint64_t) allocation_count;
static _Atomic(uint64_t) deallocation_count;
static _Atomic(uint64_t) lock_count;
static _Atomic(uint64_t) print_count;
static _Atomic(uint64_t) io_count;
static _Atomic(uint64_t) callback_entry_count;
static __thread uint32_t callback_scope_depth
    __attribute__((tls_model("initial-exec")));

static inline void record_if_scoped(_Atomic(uint64_t) *counter) {
    if (callback_scope_depth != 0) {
        atomic_fetch_add_explicit(counter, 1, memory_order_relaxed);
    }
}

void pluginhost_rt_instrumentation_scope_enter(void) {
    atomic_fetch_add_explicit(&callback_entry_count, 1, memory_order_relaxed);
    callback_scope_depth += 1;
}

void pluginhost_rt_instrumentation_scope_leave(void) {
    if (callback_scope_depth != 0) {
        callback_scope_depth -= 1;
    }
}

void pluginhost_rt_instrumentation_reset(void) {
    atomic_store_explicit(&allocation_count, 0, memory_order_relaxed);
    atomic_store_explicit(&deallocation_count, 0, memory_order_relaxed);
    atomic_store_explicit(&lock_count, 0, memory_order_relaxed);
    atomic_store_explicit(&print_count, 0, memory_order_relaxed);
    atomic_store_explicit(&io_count, 0, memory_order_relaxed);
    atomic_store_explicit(&callback_entry_count, 0, memory_order_relaxed);
}

pluginhost_rt_instrumentation_report
pluginhost_rt_instrumentation_snapshot(void) {
    pluginhost_rt_instrumentation_report result;
    result.allocations = atomic_load_explicit(&allocation_count,
                                               memory_order_acquire);
    result.deallocations = atomic_load_explicit(&deallocation_count,
                                                 memory_order_acquire);
    result.locks = atomic_load_explicit(&lock_count, memory_order_acquire);
    result.prints = atomic_load_explicit(&print_count, memory_order_acquire);
    result.io = atomic_load_explicit(&io_count, memory_order_acquire);
    result.callback_entries = atomic_load_explicit(&callback_entry_count,
                                                    memory_order_acquire);
    return result;
}

/* JACK callback wrappers. GNU ld --wrap redirects backend registrations here. */
int __real_pluginhost_jack_process_callback(jack_nframes_t, void *);
void __real_pluginhost_jack_shutdown_callback(void *);
void __real_pluginhost_jack_info_shutdown_callback(jack_status_t, const char *,
                                                    void *);
int __real_pluginhost_jack_buffer_size_callback(jack_nframes_t, void *);
int __real_pluginhost_jack_sample_rate_callback(jack_nframes_t, void *);
int __real_pluginhost_jack_xrun_callback(void *);
void __real_pluginhost_jack_freewheel_callback(int, void *);
void __real_pluginhost_jack_latency_callback(jack_latency_callback_mode_t,
                                              void *);

int __wrap_pluginhost_jack_process_callback(jack_nframes_t frames,
                                             void *argument) {
    pluginhost_rt_instrumentation_scope_enter();
    int result = __real_pluginhost_jack_process_callback(frames, argument);
    pluginhost_rt_instrumentation_scope_leave();
    return result;
}

void __wrap_pluginhost_jack_shutdown_callback(void *argument) {
    pluginhost_rt_instrumentation_scope_enter();
    __real_pluginhost_jack_shutdown_callback(argument);
    pluginhost_rt_instrumentation_scope_leave();
}

void __wrap_pluginhost_jack_info_shutdown_callback(jack_status_t status,
                                                    const char *reason,
                                                    void *argument) {
    pluginhost_rt_instrumentation_scope_enter();
    __real_pluginhost_jack_info_shutdown_callback(status, reason, argument);
    pluginhost_rt_instrumentation_scope_leave();
}

int __wrap_pluginhost_jack_buffer_size_callback(jack_nframes_t frames,
                                                 void *argument) {
    pluginhost_rt_instrumentation_scope_enter();
    int result = __real_pluginhost_jack_buffer_size_callback(frames, argument);
    pluginhost_rt_instrumentation_scope_leave();
    return result;
}

int __wrap_pluginhost_jack_sample_rate_callback(jack_nframes_t frames,
                                                 void *argument) {
    pluginhost_rt_instrumentation_scope_enter();
    int result = __real_pluginhost_jack_sample_rate_callback(frames, argument);
    pluginhost_rt_instrumentation_scope_leave();
    return result;
}

int __wrap_pluginhost_jack_xrun_callback(void *argument) {
    pluginhost_rt_instrumentation_scope_enter();
    int result = __real_pluginhost_jack_xrun_callback(argument);
    pluginhost_rt_instrumentation_scope_leave();
    return result;
}

void __wrap_pluginhost_jack_freewheel_callback(int starting, void *argument) {
    pluginhost_rt_instrumentation_scope_enter();
    __real_pluginhost_jack_freewheel_callback(starting, argument);
    pluginhost_rt_instrumentation_scope_leave();
}

void __wrap_pluginhost_jack_latency_callback(jack_latency_callback_mode_t mode,
                                              void *argument) {
    pluginhost_rt_instrumentation_scope_enter();
    __real_pluginhost_jack_latency_callback(mode, argument);
    pluginhost_rt_instrumentation_scope_leave();
}

/* Allocation and deallocation wrappers. */
void *__real_malloc(size_t);
void *__real_calloc(size_t, size_t);
void *__real_realloc(void *, size_t);
void __real_free(void *);
void *__real_aligned_alloc(size_t, size_t);
int __real_posix_memalign(void **, size_t, size_t);
void *__real_mmap(void *, size_t, int, int, int, off_t);
int __real_munmap(void *, size_t);

void *__wrap_malloc(size_t size) {
    record_if_scoped(&allocation_count);
    return __real_malloc(size);
}

void *__wrap_calloc(size_t count, size_t size) {
    record_if_scoped(&allocation_count);
    return __real_calloc(count, size);
}

void *__wrap_realloc(void *memory, size_t size) {
    record_if_scoped(&allocation_count);
    if (memory != NULL) {
        record_if_scoped(&deallocation_count);
    }
    return __real_realloc(memory, size);
}

void __wrap_free(void *memory) {
    if (memory != NULL) {
        record_if_scoped(&deallocation_count);
    }
    __real_free(memory);
}

void *__wrap_aligned_alloc(size_t alignment, size_t size) {
    record_if_scoped(&allocation_count);
    return __real_aligned_alloc(alignment, size);
}

int __wrap_posix_memalign(void **memory, size_t alignment, size_t size) {
    record_if_scoped(&allocation_count);
    return __real_posix_memalign(memory, alignment, size);
}

void *__wrap_mmap(void *address, size_t length, int protection, int flags,
                  int descriptor, off_t offset) {
    record_if_scoped(&allocation_count);
    return __real_mmap(address, length, protection, flags, descriptor, offset);
}

int __wrap_munmap(void *address, size_t length) {
    record_if_scoped(&deallocation_count);
    return __real_munmap(address, length);
}

/* Lock and wait wrappers. */
int __real_pthread_mutex_lock(pthread_mutex_t *);
int __real_pthread_mutex_trylock(pthread_mutex_t *);
int __real_pthread_mutex_timedlock(pthread_mutex_t *, const struct timespec *);
int __real_pthread_rwlock_rdlock(pthread_rwlock_t *);
int __real_pthread_rwlock_wrlock(pthread_rwlock_t *);
int __real_pthread_rwlock_tryrdlock(pthread_rwlock_t *);
int __real_pthread_rwlock_trywrlock(pthread_rwlock_t *);
int __real_pthread_spin_lock(pthread_spinlock_t *);
int __real_pthread_spin_trylock(pthread_spinlock_t *);
int __real_pthread_cond_wait(pthread_cond_t *, pthread_mutex_t *);
int __real_pthread_cond_timedwait(pthread_cond_t *, pthread_mutex_t *,
                                  const struct timespec *);

#define PLUGINHOST_WRAP_LOCK_ONE(name, type) \
    int __wrap_##name(type *value) {          \
        record_if_scoped(&lock_count);        \
        return __real_##name(value);          \
    }

PLUGINHOST_WRAP_LOCK_ONE(pthread_mutex_lock, pthread_mutex_t)
PLUGINHOST_WRAP_LOCK_ONE(pthread_mutex_trylock, pthread_mutex_t)
PLUGINHOST_WRAP_LOCK_ONE(pthread_rwlock_rdlock, pthread_rwlock_t)
PLUGINHOST_WRAP_LOCK_ONE(pthread_rwlock_wrlock, pthread_rwlock_t)
PLUGINHOST_WRAP_LOCK_ONE(pthread_rwlock_tryrdlock, pthread_rwlock_t)
PLUGINHOST_WRAP_LOCK_ONE(pthread_rwlock_trywrlock, pthread_rwlock_t)
PLUGINHOST_WRAP_LOCK_ONE(pthread_spin_lock, pthread_spinlock_t)
PLUGINHOST_WRAP_LOCK_ONE(pthread_spin_trylock, pthread_spinlock_t)

int __wrap_pthread_mutex_timedlock(pthread_mutex_t *mutex,
                                   const struct timespec *deadline) {
    record_if_scoped(&lock_count);
    return __real_pthread_mutex_timedlock(mutex, deadline);
}

int __wrap_pthread_cond_wait(pthread_cond_t *condition, pthread_mutex_t *mutex) {
    record_if_scoped(&lock_count);
    return __real_pthread_cond_wait(condition, mutex);
}

int __wrap_pthread_cond_timedwait(pthread_cond_t *condition,
                                  pthread_mutex_t *mutex,
                                  const struct timespec *deadline) {
    record_if_scoped(&lock_count);
    return __real_pthread_cond_timedwait(condition, mutex, deadline);
}

/* Print wrappers. */
int __real_vprintf(const char *, va_list);
int __real_vfprintf(FILE *, const char *, va_list);
int __real_vsprintf(char *, const char *, va_list);
int __real_vsnprintf(char *, size_t, const char *, va_list);
int __real_puts(const char *);
int __real_fputs(const char *, FILE *);
size_t __real_fwrite(const void *, size_t, size_t, FILE *);
int __real_putchar(int);

int __wrap_vprintf(const char *format, va_list arguments) {
    record_if_scoped(&print_count);
    return __real_vprintf(format, arguments);
}

int __wrap_printf(const char *format, ...) {
    record_if_scoped(&print_count);
    va_list arguments;
    va_start(arguments, format);
    int result = __real_vprintf(format, arguments);
    va_end(arguments);
    return result;
}

int __wrap_vfprintf(FILE *stream, const char *format, va_list arguments) {
    record_if_scoped(&print_count);
    return __real_vfprintf(stream, format, arguments);
}

int __wrap_fprintf(FILE *stream, const char *format, ...) {
    record_if_scoped(&print_count);
    va_list arguments;
    va_start(arguments, format);
    int result = __real_vfprintf(stream, format, arguments);
    va_end(arguments);
    return result;
}

int __wrap_vsprintf(char *destination, const char *format, va_list arguments) {
    record_if_scoped(&print_count);
    return __real_vsprintf(destination, format, arguments);
}

int __wrap_sprintf(char *destination, const char *format, ...) {
    record_if_scoped(&print_count);
    va_list arguments;
    va_start(arguments, format);
    int result = __real_vsprintf(destination, format, arguments);
    va_end(arguments);
    return result;
}

int __wrap_vsnprintf(char *destination, size_t size, const char *format,
                     va_list arguments) {
    record_if_scoped(&print_count);
    return __real_vsnprintf(destination, size, format, arguments);
}

int __wrap_snprintf(char *destination, size_t size, const char *format, ...) {
    record_if_scoped(&print_count);
    va_list arguments;
    va_start(arguments, format);
    int result = __real_vsnprintf(destination, size, format, arguments);
    va_end(arguments);
    return result;
}

int __wrap_puts(const char *text) {
    record_if_scoped(&print_count);
    return __real_puts(text);
}

int __wrap_fputs(const char *text, FILE *stream) {
    record_if_scoped(&print_count);
    return __real_fputs(text, stream);
}

size_t __wrap_fwrite(const void *data, size_t size, size_t count, FILE *stream) {
    record_if_scoped(&print_count);
    return __real_fwrite(data, size, count, stream);
}

int __wrap_putchar(int character) {
    record_if_scoped(&print_count);
    return __real_putchar(character);
}

/* Direct file-I/O wrappers. */
int __real_open(const char *, int, ...);
int __real_open64(const char *, int, ...);
int __real_openat(int, const char *, int, ...);
int __real_openat64(int, const char *, int, ...);
ssize_t __real_read(int, void *, size_t);
ssize_t __real_pread(int, void *, size_t, off_t);
ssize_t __real_write(int, const void *, size_t);
ssize_t __real_pwrite(int, const void *, size_t, off_t);
ssize_t __real_writev(int, const struct iovec *, int);
int __real_close(int);
int __real_fsync(int);
int __real_fdatasync(int);

static mode_t open_mode(int flags, va_list arguments) {
    if ((flags & O_CREAT) != 0 || (flags & O_TMPFILE) == O_TMPFILE) {
        return (mode_t)va_arg(arguments, int);
    }
    return 0;
}

#define PLUGINHOST_WRAP_OPEN(name)                                      \
    int __wrap_##name(const char *path, int flags, ...) {               \
        record_if_scoped(&io_count);                                    \
        va_list arguments;                                              \
        va_start(arguments, flags);                                     \
        mode_t mode = open_mode(flags, arguments);                      \
        va_end(arguments);                                              \
        if ((flags & O_CREAT) != 0 || (flags & O_TMPFILE) == O_TMPFILE) \
            return __real_##name(path, flags, mode);                    \
        return __real_##name(path, flags);                              \
    }

PLUGINHOST_WRAP_OPEN(open)
PLUGINHOST_WRAP_OPEN(open64)

#define PLUGINHOST_WRAP_OPENAT(name)                                    \
    int __wrap_##name(int directory, const char *path, int flags, ...) {\
        record_if_scoped(&io_count);                                    \
        va_list arguments;                                              \
        va_start(arguments, flags);                                     \
        mode_t mode = open_mode(flags, arguments);                      \
        va_end(arguments);                                              \
        if ((flags & O_CREAT) != 0 || (flags & O_TMPFILE) == O_TMPFILE) \
            return __real_##name(directory, path, flags, mode);         \
        return __real_##name(directory, path, flags);                   \
    }

PLUGINHOST_WRAP_OPENAT(openat)
PLUGINHOST_WRAP_OPENAT(openat64)

ssize_t __wrap_read(int descriptor, void *buffer, size_t size) {
    record_if_scoped(&io_count);
    return __real_read(descriptor, buffer, size);
}

ssize_t __wrap_pread(int descriptor, void *buffer, size_t size, off_t offset) {
    record_if_scoped(&io_count);
    return __real_pread(descriptor, buffer, size, offset);
}

ssize_t __wrap_write(int descriptor, const void *buffer, size_t size) {
    record_if_scoped(&io_count);
    return __real_write(descriptor, buffer, size);
}

ssize_t __wrap_pwrite(int descriptor, const void *buffer, size_t size,
                      off_t offset) {
    record_if_scoped(&io_count);
    return __real_pwrite(descriptor, buffer, size, offset);
}

ssize_t __wrap_writev(int descriptor, const struct iovec *vectors, int count) {
    record_if_scoped(&io_count);
    return __real_writev(descriptor, vectors, count);
}

int __wrap_close(int descriptor) {
    record_if_scoped(&io_count);
    return __real_close(descriptor);
}

int __wrap_fsync(int descriptor) {
    record_if_scoped(&io_count);
    return __real_fsync(descriptor);
}

int __wrap_fdatasync(int descriptor) {
    record_if_scoped(&io_count);
    return __real_fdatasync(descriptor);
}

int pluginhost_rt_instrumentation_self_test(void) {
    int descriptor = __real_open("/dev/null", O_WRONLY);
    FILE *stream = fopen("/dev/null", "w");
    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    if (descriptor < 0 || stream == NULL) {
        if (descriptor >= 0) __real_close(descriptor);
        if (stream != NULL) fclose(stream);
        return -1;
    }

    pluginhost_rt_instrumentation_reset();
    pluginhost_rt_instrumentation_scope_enter();
    volatile void *memory = malloc(16);
    memory = realloc((void *)memory, 32);
    free((void *)memory);
    if (pthread_mutex_lock(&mutex) == 0) {
        pthread_mutex_unlock(&mutex);
    }
    fprintf(stream, "%s", "");
    (void)write(descriptor, "", 0);
    pluginhost_rt_instrumentation_scope_leave();

    pthread_mutex_destroy(&mutex);
    fclose(stream);
    __real_close(descriptor);

    pluginhost_rt_instrumentation_report report =
        pluginhost_rt_instrumentation_snapshot();
    return report.allocations > 0 && report.deallocations > 0 &&
           report.locks > 0 && report.prints > 0 && report.io > 0 ? 0 : -2;
}
