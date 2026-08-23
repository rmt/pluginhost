when not defined(linux):
  {.error: "pluginhost/platform/linux/dynlib is available only on Linux".}

import std/posix

import ../../domain/[errors, result]

type
  DynamicSymbol = ptr | pointer | proc

  DynamicLibrary* = object
    ## Move-only owner for one dlopen handle.
    ##
    ## Call close explicitly on every successful open. There is deliberately no
    ## implicit unload: loader failures must remain visible to the control plane.
    handle: pointer
    path: string

proc `=destroy`*(library: var DynamicLibrary) =
  # Foreign close errors cannot be returned from a destructor. Ownership is
  # therefore released only by the checked explicit close operation.
  `=destroy`(library.path)

proc `=copy`*(destination: var DynamicLibrary; source: DynamicLibrary) {.error:
  "DynamicLibrary owns a handle and cannot be copied; use move".}
proc `=dup`*(source: DynamicLibrary): DynamicLibrary {.error:
  "DynamicLibrary owns a handle and cannot be duplicated; use move".}

proc `=sink`*(destination: var DynamicLibrary; source: DynamicLibrary) =
  doAssert destination.handle == nil,
    "an open DynamicLibrary must be closed before move assignment"
  destination.handle = source.handle
  `=sink`(destination.path, source.path)

proc loaderDetail(fallback: string): string =
  let detail = dlerror()
  if detail == nil:
    fallback
  else:
    $detail

proc loaderError(kind: HostErrorKind; message, path, detail: string;
                 symbol = ""): HostError =
  var context = "path=" & path
  if symbol.len > 0:
    context.add("; symbol=" & symbol)
  if detail.len > 0:
    context.add("; loader=" & detail)
  hostError(hsPlatform, kind, message, context)

proc libraryPath*(library: DynamicLibrary): string {.inline.} =
  library.path

proc isOpen*(library: DynamicLibrary): bool {.inline.} =
  library.handle != nil

proc openDynamicLibrary*(path: string): Result[DynamicLibrary] =
  if path.len == 0:
    return failure[DynamicLibrary](loaderError(
      hekLibraryOpen,
      "could not open dynamic library",
      path,
      "path is empty",
    ))

  discard dlerror()
  let handle = dlopen(path.cstring, RTLD_NOW or RTLD_LOCAL)
  if handle == nil:
    return failure[DynamicLibrary](loaderError(
      hekLibraryOpen,
      "could not open dynamic library",
      path,
      loaderDetail("dlopen returned a null handle"),
    ))

  success(DynamicLibrary(handle: handle, path: path))

proc resolveAddress*(library: DynamicLibrary;
                     symbol: string): Result[pointer] =
  if library.handle == nil:
    return failure[pointer](loaderError(
      hekSymbolLookup,
      "could not resolve dynamic-library symbol",
      library.path,
      "library is closed",
      symbol,
    ))
  if symbol.len == 0:
    return failure[pointer](loaderError(
      hekSymbolLookup,
      "could not resolve dynamic-library symbol",
      library.path,
      "symbol name is empty",
    ))

  discard dlerror()
  let address = dlsym(library.handle, symbol.cstring)
  let detail = dlerror()
  if detail != nil:
    return failure[pointer](loaderError(
      hekSymbolLookup,
      "could not resolve dynamic-library symbol",
      library.path,
      $detail,
      symbol,
    ))
  if address == nil:
    return failure[pointer](loaderError(
      hekSymbolLookup,
      "could not resolve dynamic-library symbol",
      library.path,
      "symbol resolved to a null address",
      symbol,
    ))

  success(address)

proc resolveSymbol*[T: DynamicSymbol](library: DynamicLibrary;
                       symbol: string): Result[T] =
  static:
    doAssert sizeof(T) == sizeof(pointer),
      "dynamic symbols must use a pointer-sized data or procedure type"

  var addressResult = library.resolveAddress(symbol)
  if not addressResult.isOk:
    return failure[T](move(addressResult.error))
  success(cast[T](addressResult.value))

proc close*(library: var DynamicLibrary): Result[Unit] =
  if library.handle == nil:
    return success()

  discard dlerror()
  if dlclose(library.handle) != 0:
    return failure[Unit](loaderError(
      hekLibraryClose,
      "could not close dynamic library",
      library.path,
      loaderDetail("dlclose failed"),
    ))

  library.handle = nil
  success()
