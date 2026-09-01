import std/[os, posix, strutils]

import ../../domain/[errors, result]

const
  TempNameAttempts = 64
  LinuxONoFollow = 0x0002_0000.cint

type
  PidFile* = object
    pathValue: string
    device: Dev
    inode: Ino
    owned: bool

proc pidError(message, path: string; code = osLastError();
              detail = ""): HostError =
  var context = "path=" & path
  if detail.len > 0:
    context.add("; " & detail)
  context.add("; errno=" & $int(code) & " [" & osErrorMsg(code) & "]")
  hostError(hsPlatform, hekPidFile, message, context)

proc `=destroy`*(file: var PidFile) =
  doAssert not file.owned, "a PID file must be explicitly removed"
  `=destroy`(file.pathValue)

proc `=copy`*(destination: var PidFile; source: PidFile) {.error:
  "PidFile owns a filesystem entry and cannot be copied; use move".}
proc `=dup`*(source: PidFile): PidFile {.error:
  "PidFile owns a filesystem entry and cannot be duplicated; use move".}

proc `=sink`*(destination: var PidFile; source: PidFile) =
  doAssert not destination.owned,
    "a PID file must be removed before move assignment"
  `=sink`(destination.pathValue, source.pathValue)
  destination.device = source.device
  destination.inode = source.inode
  destination.owned = source.owned

proc path*(file: PidFile): string {.inline.} = file.pathValue
proc isOwned*(file: PidFile): bool {.inline.} = file.owned

proc closeFd(fd: cint; path: string): Result[Unit] =
  if posix.close(fd) != 0:
    return failure[Unit](pidError("could not close the PID temporary file", path))
  success()

proc writeAll(fd: cint; content, path: string): Result[Unit] =
  var written = 0
  while written < content.len:
    let count = posix.write(fd, unsafeAddr content[written],
                            content.len - written)
    if count < 0:
      if osLastError() == OSErrorCode(EINTR):
        continue
      return failure[Unit](pidError("could not write the PID temporary file", path))
    if count == 0:
      return failure[Unit](hostError(
        hsPlatform, hekPidFile, "PID temporary-file write made no progress",
        "path=" & path))
    written += int(count)
  success()

proc removeIfPresent(path: string) =
  if path.len > 0:
    discard posix.unlink(path.cstring)

proc createPidFile*(path: string): Result[PidFile] =
  if path.len == 0 or path.find('\0') >= 0:
    return failure[PidFile](hostError(
      hsPlatform, hekPidFile, "PID-file path is invalid", "path=" & path))

  let parent = if path.splitFile.dir.len == 0: "." else: path.splitFile.dir
  let base = path.splitFile.name & path.splitFile.ext
  let processId = int(getpid())
  var temporary = ""
  var fd = -1.cint
  for attempt in 0 ..< TempNameAttempts:
    temporary = parent / ("." & base & ".pluginhost-" & $processId &
      "-" & $attempt & ".tmp")
    fd = posix.open(temporary.cstring,
      O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC or LinuxONoFollow,
      Mode(S_IRUSR or S_IWUSR))
    if fd >= 0:
      break
    if osLastError() != OSErrorCode(EEXIST):
      return failure[PidFile](pidError(
        "could not create the PID temporary file", temporary))
  if fd < 0:
    return failure[PidFile](hostError(
      hsPlatform, hekPidFile,
      "could not allocate a unique PID temporary-file name",
      "path=" & path & "; attempts=" & $TempNameAttempts))

  let content = $processId & "\n"
  var wrote = writeAll(fd, content, temporary)
  if not wrote.isOk:
    discard posix.close(fd)
    removeIfPresent(temporary)
    return failure[PidFile](move(wrote.error))
  if fsync(fd) != 0:
    let error = pidError("could not synchronize the PID temporary file", temporary)
    discard posix.close(fd)
    removeIfPresent(temporary)
    return failure[PidFile](error)
  var closed = closeFd(fd, temporary)
  if not closed.isOk:
    removeIfPresent(temporary)
    return failure[PidFile](move(closed.error))

  if posix.link(temporary.cstring, path.cstring) != 0:
    let code = osLastError()
    removeIfPresent(temporary)
    let message = if code == OSErrorCode(EEXIST):
        "PID file already exists"
      else:
        "could not atomically publish the PID file"
    return failure[PidFile](pidError(message, path, code))

  if posix.unlink(temporary.cstring) != 0:
    let primary = pidError("could not remove the published PID temporary name",
                           temporary)
    discard posix.unlink(path.cstring)
    return failure[PidFile](primary)

  var status: Stat
  if lstat(path.cstring, status) != 0:
    let primary = pidError("could not inspect the published PID file", path)
    discard posix.unlink(path.cstring)
    return failure[PidFile](primary)

  success(PidFile(
    pathValue: path,
    device: status.st_dev,
    inode: status.st_ino,
    owned: true,
  ))

proc close*(file: var PidFile): Result[Unit] =
  if not file.owned:
    return success()

  var status: Stat
  if lstat(file.pathValue.cstring, status) != 0:
    let code = osLastError()
    if code == OSErrorCode(ENOENT):
      file.owned = false
      file.pathValue.setLen(0)
      return success()
    file.owned = false
    return failure[Unit](pidError(
      "could not inspect the owned PID file during removal",
      file.pathValue, code))

  if status.st_dev != file.device or status.st_ino != file.inode:
    let path = file.pathValue
    file.owned = false
    file.pathValue.setLen(0)
    return failure[Unit](hostError(
      hsPlatform, hekPidFile,
      "PID-file path no longer refers to the entry created by this process",
      "path=" & path))

  if posix.unlink(file.pathValue.cstring) != 0:
    return failure[Unit](pidError("could not remove the PID file", file.pathValue))
  file.owned = false
  file.pathValue.setLen(0)
  success()
