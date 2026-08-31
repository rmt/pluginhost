# ADR 0003: Use one Nim callback-safety build profile

- Status: Accepted
- Date: 2026-08-28

## Context

The host executes Nim callbacks on foreign CLAP and JACK threads. Nim's
`raises: []` effect excludes ordinary exceptions but does not by itself prevent
`Defect` values from unwinding when panic mode is disabled. The product and its
real-time evidence also previously used different memory managers: ordinary
builds used ORC while ABI and RT tasks selected ARC explicitly.

Nim installs process signal handlers unless `noSignalHandler` is defined. The
host needs explicit Linux signal ownership so JACK-created threads can inherit a
blocked signal mask before the eventual reactor consumes those signals.

## Decision

All project builds use the profile defined in `config.nims`:

- `--mm:arc`
- `--threads:on`
- `--panics:on`
- `-d:noSignalHandler`

Control-plane compiler checks remain enabled. Every foreign callback and every
real-time module additionally disables runtime checks, stack traces, and line
traces in its generated callback path and validates untrusted values explicitly
before unchecked access. Callback procedures remain non-capturing and use the
exact ABI convention, `gcsafe`, and `raises: []`.

`--panics:on` is a final ABI fault barrier, not an error-recovery mechanism: a
missed defect terminates the process rather than unwinding into foreign code.
The callback rules are still required to prevent defects and real-time-unsafe
runtime activity in the first place.

ADR 0005 supplements this decision for atomics: Nim 2.2.10's standard atomic
helpers retain trace frames despite caller-local pragmas, so process-reachable callback
state uses an audited C11 bridge rather than permitting those transitive helpers.

## Alternatives considered

- Keep ORC for ordinary builds and ARC only for RT tests: rejected because the
  evidence would not describe the shipped configuration.
- Rely on `raises: []`: rejected because Defects are outside that effect set.
- Disable checks globally: rejected because the control plane benefits from
  debug checks and is not subject to callback timing constraints.
- Keep Nim's signal handlers: rejected because they bypass orderly host policy
  and signal delivery could occur on a JACK-created thread.

## Consequences

- Product, unit, fixture, ABI, and RT builds exercise the same memory, thread,
  panic, and signal configuration.
- Callback code must provide explicit precondition checks before entering its
  unchecked region.
- Defects outside callbacks are fatal rather than catchable.
- The future signal service must install explicit process-control behavior and
  block handled signals before opening JACK.
