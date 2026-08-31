import ./[audio_slice, run_config]
import ../domain/[errors, lifecycle, result]

type
  HostSession* = object
    state*: SessionState
    audioSlice: InternalAudioSlice

proc initHostSession*(): HostSession =
  HostSession(state: ssNew)

proc attachInternalAudioSlice*(session: var HostSession;
                                slice: sink InternalAudioSlice): Result[Unit] =
  if session.state != ssNew or slice.state != iassReady:
    return failure[Unit](transitionError(
      "an internal audio slice can only be attached to a new session",
      $session.state & "; slice=" & $slice.state,
    ))
  session.audioSlice = move(slice)
  success()

proc startInternalAudio*(session: var HostSession): Result[Unit] =
  if session.state != ssNew or session.audioSlice.state != iassReady:
    return failure[Unit](transitionError(
      "an internal audio slice can only start from a new ready session",
      $session.state & "; slice=" & $session.audioSlice.state,
    ))
  var starting = session.state.transition(ssStarting)
  if not starting.isOk:
    return starting
  var started = session.audioSlice.start()
  if not started.isOk:
    discard session.state.transition(ssFailed)
    return started
  session.state.transition(ssRunning)

proc stopInternalAudio*(session: var HostSession): Result[Unit] =
  if session.state != ssRunning:
    return failure[Unit](transitionError(
      "an internal audio slice can only stop from a running session",
      $session.state,
    ))
  var stopping = session.state.transition(ssStopping)
  if not stopping.isOk:
    return stopping
  var stopped = session.audioSlice.stop()
  if not stopped.isOk:
    discard session.state.transition(ssFailed)
    return stopped
  session.state.transition(ssStopped)

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
  var audioClosed = session.audioSlice.close()
  if not audioClosed.isOk:
    return audioClosed
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
