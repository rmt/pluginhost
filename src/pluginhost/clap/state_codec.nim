## Main-thread CLAP state streams backed by bounded POSIX files.
import std/[os, posix, strutils]

import ./ffi
import ../domain/[errors, result]

const
  ClapStateTransferBytes* = 64 * 1024'u64
  ClapStateMaximumBytes* = 64 * 1024 * 1024'u64
  TempNameAttempts = 64
  LinuxONoFollow = 0x0002_0000.cint

proc cRename(oldPath, newPath: cstring): cint {.importc: "rename", header: "stdio.h".}

type
  ClapStateInput* = object
    stream: ClapIStream
    fd: cint
    failed: bool
    transferred: uint64
    path: string
  ClapStateOutput* = object
    stream: ClapOStream
    fd: cint
    failed: bool
    committed: bool
    transferred: uint64
    target, temporary: string

proc stateError(message, path: string): HostError =
  hostError(hsState, hekState, message,
    "path=" & path & "; errno=" & $int(osLastError()) & " [" & osErrorMsg(osLastError()) & "]")

proc readStream(stream: ptr ClapIStream; buffer: pointer; size: uint64): int64 {.cdecl, gcsafe, raises: [].} =
  let state = cast[ptr ClapStateInput](if stream == nil: nil else: stream.ctx)
  if state == nil:
    return -1
  if state.fd < 0 or (size > 0'u64 and buffer == nil):
    state.failed = true
    return -1
  if size == 0'u64:
    return 0
  let amount = min(size, min(ClapStateTransferBytes, ClapStateMaximumBytes - state.transferred))
  if amount == 0'u64: state.failed = true; return -1
  while true:
    let got = posix.read(state.fd, buffer, int(amount))
    if got >= 0:
      state.transferred += uint64(got)
      return int64(got)
    if osLastError() != OSErrorCode(EINTR): state.failed = true; return -1

proc writeStream(stream: ptr ClapOStream; buffer: pointer; size: uint64): int64 {.cdecl, gcsafe, raises: [].} =
  let state = cast[ptr ClapStateOutput](if stream == nil: nil else: stream.ctx)
  if state == nil:
    return -1
  if state.fd < 0 or (size > 0'u64 and buffer == nil):
    state.failed = true
    return -1
  if size == 0'u64:
    return 0
  let amount = min(size, min(ClapStateTransferBytes, ClapStateMaximumBytes - state.transferred))
  if amount == 0'u64: state.failed = true; return -1
  while true:
    let wrote = posix.write(state.fd, buffer, int(amount))
    if wrote > 0:
      state.transferred += uint64(wrote)
      return int64(wrote)
    if wrote == 0 or osLastError() != OSErrorCode(EINTR): state.failed = true; return -1

proc openStateInput*(path: string): Result[ClapStateInput] =
  if path.len == 0 or path.find('\0') >= 0: return failure[ClapStateInput](hostError(hsState, hekState, "state input path is invalid", "path=" & path))
  let fd = posix.open(path.cstring, O_RDONLY or O_CLOEXEC or LinuxONoFollow)
  if fd < 0: return failure[ClapStateInput](stateError("could not open state input", path))
  success(ClapStateInput(fd: fd, path: path, stream: ClapIStream(
    ctx: nil, read: readStream)))

proc streamPointer*(input: var ClapStateInput): ptr ClapIStream =
  input.stream.ctx = addr input
  addr input.stream
proc failed*(input: ClapStateInput): bool = input.failed
proc close*(input: var ClapStateInput): Result[Unit] =
  if input.fd < 0: return success()
  if posix.close(input.fd) != 0: return failure[Unit](stateError("could not close state input", input.path))
  input.fd = -1; success()

proc openStateOutput*(target: string): Result[ClapStateOutput] =
  if target.len == 0 or target.find('\0') >= 0: return failure[ClapStateOutput](hostError(hsState, hekState, "state output path is invalid", "path=" & target))
  let parent = if target.splitFile.dir.len == 0: "." else: target.splitFile.dir
  let base = target.splitFile.name & target.splitFile.ext
  for attempt in 0 ..< TempNameAttempts:
    let temporary = parent / ("." & base & ".pluginhost-state-" & $int(getpid()) & "-" & $attempt & ".tmp")
    let fd = posix.open(temporary.cstring, O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC or LinuxONoFollow, Mode(S_IRUSR or S_IWUSR))
    if fd >= 0:
      return success(ClapStateOutput(fd: fd, target: target, temporary: temporary,
        stream: ClapOStream(ctx: nil, write: writeStream)))
    if osLastError() != OSErrorCode(EEXIST):
      return failure[ClapStateOutput](stateError(
        "could not create state temporary file", temporary))
  failure[ClapStateOutput](hostError(hsState, hekState,
    "could not allocate a unique state temporary file", "path=" & target))

proc streamPointer*(output: var ClapStateOutput): ptr ClapOStream =
  output.stream.ctx = addr output
  addr output.stream
proc failed*(output: ClapStateOutput): bool = output.failed
proc rollback*(output: var ClapStateOutput) =
  if output.fd >= 0: discard posix.close(output.fd); output.fd = -1
  if not output.committed and output.temporary.len > 0: discard posix.unlink(output.temporary.cstring)

proc commit*(output: var ClapStateOutput): Result[Unit] =
  if output.failed or output.fd < 0:
    output.rollback()
    return failure[Unit](hostError(hsState, hekState, "state output stream failed", "path=" & output.target))
  if fsync(output.fd) != 0:
    let error = stateError("could not synchronize state temporary file", output.temporary)
    output.rollback()
    return failure[Unit](error)
  if posix.close(output.fd) != 0:
    output.fd = -1
    output.rollback()
    return failure[Unit](stateError("could not close state temporary file", output.temporary))
  output.fd = -1
  if cRename(output.temporary.cstring, output.target.cstring) != 0:
    let error = stateError("could not atomically publish state file", output.target)
    output.rollback()
    return failure[Unit](error)
  output.committed = true
  output.temporary.setLen(0)
  success()
