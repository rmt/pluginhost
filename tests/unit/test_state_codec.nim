import std/[os, strutils, unittest]

import pluginhost/clap/state_codec
import pluginhost/domain/result

proc stateTemporaries(root: string): seq[string] =
  for kind, path in walkDir(root):
    if kind == pcFile and path.endsWith(".tmp"):
      result.add(path)

suite "CLAP state streams":
  test "bounded stream writes commit atomically and read back":
    let root = getTempDir() / "pluginhost-state-codec-test"
    createDir(root)
    let path = root / "state.bin"
    defer:
      if fileExists(path): removeFile(path)
      if dirExists(root): removeDir(root)
    var openedOutput = openStateOutput(path)
    require openedOutput.isOk
    var output = move(openedOutput.value)
    let outputStream = output.streamPointer
    var bytes = [uint8(1), 2, 3, 4]
    check outputStream.write(outputStream, addr bytes[0], uint64(bytes.len)) ==
      int64(bytes.len)
    require output.commit().isOk
    check getFilePermissions(path) <= {fpUserRead, fpUserWrite}
    var openedInput = openStateInput(path)
    require openedInput.isOk
    var input = move(openedInput.value)
    let inputStream = input.streamPointer
    var copied: array[4, uint8]
    check inputStream.read(inputStream, addr copied[0], uint64(copied.len)) ==
      int64(copied.len)
    check copied == bytes
    require input.close().isOk

  test "stream errors roll back and preserve an existing destination":
    let root = getTempDir() / "pluginhost-state-codec-rollback"
    createDir(root)
    let path = root / "state.bin"
    writeFile(path, "old-state")
    defer:
      if fileExists(path): removeFile(path)
      if dirExists(root): removeDir(root)
    var opened = openStateOutput(path)
    require opened.isOk
    var output = move(opened.value)
    let stream = output.streamPointer
    check stream.write(stream, nil, 1'u64) == -1
    check output.failed
    output.rollback()
    check readFile(path) == "old-state"
    check stateTemporaries(root).len == 0

  test "commit failure rolls back its temporary without replacing a directory":
    let root = getTempDir() / "pluginhost-state-codec-commit-failure"
    createDir(root)
    let target = root / "existing-directory"
    createDir(target)
    defer:
      if dirExists(target): removeDir(target)
      if dirExists(root): removeDir(root)
    var opened = openStateOutput(target)
    require opened.isOk
    var output = move(opened.value)
    let stream = output.streamPointer
    var byte = 1'u8
    require stream.write(stream, addr byte, 1'u64) == 1
    check not output.commit().isOk
    check dirExists(target)
    check stateTemporaries(root).len == 0

  test "each stream callback has a fixed transfer bound":
    let root = getTempDir() / "pluginhost-state-codec-bound"
    createDir(root)
    let path = root / "state.bin"
    defer:
      if fileExists(path): removeFile(path)
      if dirExists(root): removeDir(root)
    var opened = openStateOutput(path)
    require opened.isOk
    var output = move(opened.value)
    let stream = output.streamPointer
    var bytes = newSeq[uint8](int(ClapStateTransferBytes) + 1)
    check stream.write(stream, addr bytes[0], uint64(bytes.len)) ==
      int64(ClapStateTransferBytes)
    check stream.write(stream, addr bytes[int(ClapStateTransferBytes)], 1'u64) == 1
    require output.commit().isOk
    check getFileSize(path) == int64(bytes.len)

  test "missing and invalid input paths return state errors":
    let missing = openStateInput(getTempDir() / "pluginhost-state-does-not-exist")
    check not missing.isOk
    let invalid = openStateInput("bad\0state")
    check not invalid.isOk
