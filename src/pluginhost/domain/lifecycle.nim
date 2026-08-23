import ./[errors, result]

type
  SessionState* = enum
    ssNew
    ssStarting
    ssRunning
    ssStopping
    ssStopped
    ssFailed

proc canTransition*(current, next: SessionState): bool =
  case current
  of ssNew:
    next in {ssStarting, ssStopping, ssStopped}
  of ssStarting:
    next in {ssRunning, ssStopping, ssFailed}
  of ssRunning:
    next in {ssStopping, ssFailed}
  of ssStopping:
    next in {ssStopped, ssFailed}
  of ssFailed:
    next in {ssStopping, ssStopped}
  of ssStopped:
    false

proc transition*(state: var SessionState; next: SessionState): Result[Unit] =
  if state == next:
    return failure[Unit](transitionError(
      "session state transition is not idempotent",
      $state & " -> " & $next,
    ))

  if not canTransition(state, next):
    return failure[Unit](transitionError(
      "invalid session state transition",
      $state & " -> " & $next,
    ))

  state = next
  success()
