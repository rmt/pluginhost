import ./run_config
import ../domain/[errors, lifecycle, result]

type
  HostSession* = object
    state*: SessionState

proc initHostSession*(): HostSession =
  HostSession(state: ssNew)

proc run*(session: var HostSession; config: RunConfig): Result[Unit] =
  let starting = session.state.transition(ssStarting)
  if not starting.isOk:
    return starting

  let failed = session.state.transition(ssFailed)
  if not failed.isOk:
    return failed

  failure[Unit](notImplementedError(
    "plugin execution is not implemented in this development increment",
    config.pluginPath,
  ))

proc close*(session: var HostSession): Result[Unit] =
  case session.state
  of ssStopped:
    success()
  of ssNew:
    session.state.transition(ssStopped)
  of ssStopping:
    session.state.transition(ssStopped)
  of ssFailed:
    let stopping = session.state.transition(ssStopping)
    if not stopping.isOk:
      return stopping
    session.state.transition(ssStopped)
  of ssStarting, ssRunning:
    let stopping = session.state.transition(ssStopping)
    if not stopping.isOk:
      return stopping
    session.state.transition(ssStopped)
