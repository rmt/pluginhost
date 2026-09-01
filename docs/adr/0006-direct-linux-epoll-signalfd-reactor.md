# ADR 0006: Direct Linux epoll and signalfd main reactor

- **Status:** Accepted
- **Date:** 2026-09-01

## Context

The public JACK-backed run path needs one event-driven CLAP main thread. Handled
signals must be blocked before JACK creates threads, plugin callbacks must be
serviced within 33 ms without a syscall from the audio thread, and later CLAP
GUI/timer/POSIX-FD services need stale-registration protection. Production
builds already disable Nim's implicit signal handlers.

A general event-loop or GUI dependency would increase deployment and review
surface. `std/posix` provides signal masks and monotonic clocks but not the
required Linux `epoll` and `signalfd` API as one checked owner.

## Decision

Use a narrow backend-neutral reactor contract with generation-bearing tokens and
a direct Linux adapter:

- Block `SIGINT`, `SIGTERM`, `SIGUSR1`, and `SIGUSR2` with
  `pthread_sigmask()` before plugin and JACK startup.
- Consume those signals from a nonblocking close-on-exec `signalfd`; install no
  product signal handler.
- Use level-triggered `epoll` for FD readiness.
- Calculate monotonic timer and control-service waits from `CLOCK_MONOTONIC`
  rather than sleeping or polling.
- Validate slot generations after readiness delivery so removed/reused FDs and
  timers cannot dispatch stale work.
- Cap active control-service waits at 16 ms. CLAP callbacks publish only existing
  atomic request bits and perform no wakeup syscall.
- Keep raw Linux records and constants inside `platform/linux/`; verify their
  size, alignment, offsets, and imported procedure signatures against installed
  system headers.
- Own and close the epoll FD, signal FD, and previous signal mask explicitly and
  idempotently on the original CLAP main thread.

## Alternatives considered

- **Async signal handlers plus a self-pipe:** rejected because process-directed
  signals may run on a JACK thread and introduce a real-time syscall.
- **A dedicated signal thread:** workable, but adds thread ownership and wakeup
  synchronization without helping later GUI/FD multiplexing.
- **A third-party event-loop package:** rejected for the MVP because the required
  Linux surface is small and a dependency would require a separate maintenance,
  licensing, ABI, and callback audit.
- **Busy polling atomics:** rejected because the idle main loop must block.

## Consequences

The initial runtime remains Linux-specific, as already required. Main-thread
allocations are permitted, but JACK and process-reachable host callbacks remain
unchanged and syscall-free apart from documented JACK operations. Increment 8
can register CLAP timers and POSIX FDs through the same tokens without exposing
raw epoll types to application policy. The 16 ms bound is a service guarantee
when the main thread is not blocked inside third-party plugin code; no in-process
host can preempt a plugin call that does not return.
