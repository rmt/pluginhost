import std/[os, sets, strutils]

import ../domain/[errors, plugin_catalog, result]
import ../platform/linux/dynlib
import ../support/utf8
import ./ffi

const
  MaxPluginDescriptors* = 4_096'u32
  MaxDescriptorStringBytes* = 64 * 1_024
  MaxDescriptorFeatures* = 256
  MaxFeatureStringBytes* = 4 * 1_024
  MaxCatalogMetadataBytes* = 16 * 1_024 * 1_024

type ClapModule* = object
  ## Move-only owner for a loaded and successfully initialized CLAP entry.
  library: DynamicLibrary
  entry: ptr ClapPluginEntry
  factory: ptr ClapPluginFactory
  path: string
  entryInitialized: bool

proc `=destroy`*(module: var ClapModule) =
  # Checked release is explicit; destructors cannot return DSO close failures.
  `=destroy`(module.library)
  `=destroy`(module.path)

proc `=copy`*(destination: var ClapModule; source: ClapModule) {.error:
  "ClapModule owns foreign resources and cannot be copied; use move".}
proc `=dup`*(source: ClapModule): ClapModule {.error:
  "ClapModule owns foreign resources and cannot be duplicated; use move".}

proc `=sink`*(destination: var ClapModule; source: ClapModule) =
  doAssert not destination.library.isOpen and not destination.entryInitialized,
    "an open ClapModule must be closed before move assignment"
  `=sink`(destination.library, source.library)
  `=sink`(destination.path, source.path)
  destination.entry = source.entry
  destination.factory = source.factory
  destination.entryInitialized = source.entryInitialized

proc errorContext(path, detail: string): string =
  result = "path=" & path
  if detail.len > 0:
    result.add("; " & detail)

proc clapError(kind: HostErrorKind; message, path: string;
               detail = ""): HostError =
  hostError(hsClap, kind, message, errorContext(path, detail))

proc wrapPlatformError(kind: HostErrorKind; message, path: string;
                       error: HostError): HostError =
  clapError(kind, message, path, error.context)

proc mergeCleanupError(primary, cleanup: HostError): HostError =
  result = cleanup
  result.context.add("; primary=" & primary.message)
  if primary.context.len > 0:
    result.context.add(" (" & primary.context & ")")

proc modulePath*(module: ClapModule): string {.inline.} =
  module.path

proc isOpen*(module: ClapModule): bool {.inline.} =
  module.library.isOpen

proc isEntryInitialized*(module: ClapModule): bool {.inline.} =
  module.entryInitialized

proc close*(module: var ClapModule): Result[Unit] =
  if module.entryInitialized:
    let deinit = module.entry.deinit
    deinit()
    module.entryInitialized = false

  module.factory = nil
  module.entry = nil

  let closed = module.library.close()
  if not closed.isOk:
    return failure[Unit](wrapPlatformError(
      hekClapUnload,
      "could not unload CLAP library",
      module.path,
      closed.error,
    ))
  success()

proc rollback(module: var ClapModule; primary: HostError): HostError =
  let cleanup = module.close()
  if cleanup.isOk:
    primary
  else:
    mergeCleanupError(primary, cleanup.error)

proc openClapModule*(path: string;
                     keepLoaded = false): Result[ClapModule] =
  if path.len == 0:
    return failure[ClapModule](clapError(
      hekClapPath,
      "CLAP plugin path must not be empty",
      path,
    ))

  var canonicalPath: string
  try:
    canonicalPath = expandFilename(path)
  except OSError as error:
    return failure[ClapModule](clapError(
      hekClapPath,
      "could not resolve CLAP plugin path",
      path,
      error.msg,
    ))
  except ValueError as error:
    return failure[ClapModule](clapError(
      hekClapPath,
      "could not resolve CLAP plugin path",
      path,
      error.msg,
    ))

  var opened = openDynamicLibrary(canonicalPath, keepLoaded)
  if not opened.isOk:
    return failure[ClapModule](wrapPlatformError(
      hekClapEntry,
      "could not load CLAP library",
      canonicalPath,
      opened.error,
    ))

  var module = ClapModule(
    library: move(opened.value),
    path: canonicalPath,
  )

  let entryResult = resolveSymbol[ptr ClapPluginEntry](
    module.library, "clap_entry")
  if not entryResult.isOk:
    let primary = wrapPlatformError(
      hekClapEntry,
      "CLAP entry symbol is unavailable",
      canonicalPath,
      entryResult.error,
    )
    return failure[ClapModule](module.rollback(primary))
  module.entry = entryResult.value

  if not module.entry.clapVersion.isCompatible:
    let version = module.entry.clapVersion
    let primary = clapError(
      hekClapVersion,
      "CLAP entry version is incompatible",
      canonicalPath,
      "version=" & $version.major & "." & $version.minor & "." &
        $version.revision,
    )
    return failure[ClapModule](module.rollback(primary))

  if module.entry.init == nil or module.entry.deinit == nil or
      module.entry.getFactory == nil:
    let primary = clapError(
      hekClapEntry,
      "CLAP entry has a missing required callback",
      canonicalPath,
    )
    return failure[ClapModule](module.rollback(primary))

  if not module.entry.init(module.path.cstring):
    let primary = clapError(
      hekClapEntryInit,
      "CLAP entry initialization failed",
      canonicalPath,
    )
    return failure[ClapModule](module.rollback(primary))
  module.entryInitialized = true

  module.factory = cast[ptr ClapPluginFactory](
    module.entry.getFactory(ClapPluginFactoryId.cstring))
  if module.factory == nil:
    let primary = clapError(
      hekClapFactory,
      "CLAP plugin factory is unavailable",
      canonicalPath,
    )
    return failure[ClapModule](module.rollback(primary))

  if module.factory.getPluginCount == nil or
      module.factory.getPluginDescriptor == nil or
      module.factory.createPlugin == nil:
    let primary = clapError(
      hekClapFactory,
      "CLAP plugin factory has a missing required callback",
      canonicalPath,
    )
    return failure[ClapModule](module.rollback(primary))

  success(move(module))

proc createPlugin*(module: ClapModule; host: ptr ClapHost;
                   pluginId: string): Result[ptr ClapPlugin] =
  if not module.entryInitialized or module.factory == nil or
      not module.library.isOpen:
    return failure[ptr ClapPlugin](clapError(
      hekClapFactory,
      "CLAP module is not ready for plugin creation",
      module.path,
    ))
  if host == nil:
    return failure[ptr ClapPlugin](clapError(
      hekClapPluginCreate,
      "CLAP host pointer must not be null",
      module.path,
    ))
  if pluginId.strip().len == 0:
    return failure[ptr ClapPlugin](clapError(
      hekClapPluginCreate,
      "CLAP plugin ID must not be blank",
      module.path,
    ))

  let plugin = module.factory.createPlugin(
    module.factory, host, pluginId.cstring)
  if plugin == nil:
    return failure[ptr ClapPlugin](clapError(
      hekClapPluginCreate,
      "CLAP factory could not create plugin",
      module.path,
      "id=" & pluginId,
    ))
  success(plugin)

proc descriptorError(path, field, detail: string; index: int): HostError =
  clapError(
    hekClapDescriptor,
    "CLAP plugin descriptor is invalid",
    path,
    "index=" & $index & "; field=" & field & "; " & detail,
  )

proc copyText(value: cstring; field, path: string; index, maxBytes: int;
              required: bool; totalBytes: var int): Result[string] =
  if value == nil:
    if required:
      return failure[string](descriptorError(
        path, field, "mandatory value is null", index))
    return success("")

  let bytes = cast[ptr UncheckedArray[char]](value)
  var length = 0
  while length < maxBytes and bytes[length] != '\0':
    inc length
  if length == maxBytes and bytes[length] != '\0':
    return failure[string](descriptorError(
      path, field, "value exceeds " & $maxBytes & " bytes", index))

  var raw = newString(length)
  if length > 0:
    copyMem(addr raw[0], unsafeAddr bytes[0], length)
  let copied = replaceInvalidUtf8(raw)

  if required and copied.strip().len == 0:
    return failure[string](descriptorError(
      path, field, "mandatory value is blank", index))
  if copied.len > MaxCatalogMetadataBytes - totalBytes:
    return failure[string](descriptorError(
      path, field, "catalog metadata exceeds the bounded limit", index))

  totalBytes += copied.len
  success(copied)

proc copyFeatures(value: ptr cstring; path: string; index: int;
                  totalBytes: var int): Result[seq[string]] =
  if value == nil:
    return success(newSeq[string]())

  let features = cast[ptr UncheckedArray[cstring]](value)
  var copied = newSeqOfCap[string](MaxDescriptorFeatures)
  for featureIndex in 0 ..< MaxDescriptorFeatures:
    if features[featureIndex] == nil:
      return success(move(copied))
    var feature = copyText(
      features[featureIndex],
      "features[" & $featureIndex & "]",
      path,
      index,
      MaxFeatureStringBytes,
      false,
      totalBytes,
    )
    if not feature.isOk:
      return failure[seq[string]](move(feature.error))
    copied.add(move(feature.value))

  if features[MaxDescriptorFeatures] != nil:
    return failure[seq[string]](descriptorError(
      path,
      "features",
      "list exceeds " & $MaxDescriptorFeatures & " entries",
      index,
    ))
  success(move(copied))

proc readCatalog*(module: ClapModule): Result[PluginCatalog] =
  if not module.entryInitialized or module.factory == nil or
      not module.library.isOpen:
    return failure[PluginCatalog](clapError(
      hekClapFactory,
      "CLAP module is not ready for descriptor enumeration",
      module.path,
    ))

  let count = module.factory.getPluginCount(module.factory)
  if count > MaxPluginDescriptors:
    return failure[PluginCatalog](clapError(
      hekClapDescriptor,
      "CLAP plugin descriptor count exceeds the bounded limit",
      module.path,
      "count=" & $count & "; limit=" & $MaxPluginDescriptors,
    ))

  var descriptors = newSeqOfCap[PluginDescriptor](int(count))
  var ids = initHashSet[string]()
  var totalBytes = 0

  for rawIndex in 0'u32 ..< count:
    let index = int(rawIndex)
    let raw = module.factory.getPluginDescriptor(module.factory, rawIndex)
    if raw == nil:
      return failure[PluginCatalog](descriptorError(
        module.path, "descriptor", "factory returned null", index))
    if not raw.clapVersion.isCompatible:
      return failure[PluginCatalog](descriptorError(
        module.path, "clap_version", "version is incompatible", index))

    var id = copyText(raw.id, "id", module.path, index,
      MaxDescriptorStringBytes, true, totalBytes)
    if not id.isOk:
      return failure[PluginCatalog](move(id.error))
    if id.value in ids:
      return failure[PluginCatalog](descriptorError(
        module.path, "id", "duplicate ID after text validation", index))

    var name = copyText(raw.name, "name", module.path, index,
      MaxDescriptorStringBytes, true, totalBytes)
    if not name.isOk:
      return failure[PluginCatalog](move(name.error))
    var vendor = copyText(raw.vendor, "vendor", module.path, index,
      MaxDescriptorStringBytes, false, totalBytes)
    if not vendor.isOk:
      return failure[PluginCatalog](move(vendor.error))
    var url = copyText(raw.url, "url", module.path, index,
      MaxDescriptorStringBytes, false, totalBytes)
    if not url.isOk:
      return failure[PluginCatalog](move(url.error))
    var manualUrl = copyText(raw.manualUrl, "manual_url", module.path, index,
      MaxDescriptorStringBytes, false, totalBytes)
    if not manualUrl.isOk:
      return failure[PluginCatalog](move(manualUrl.error))
    var supportUrl = copyText(raw.supportUrl, "support_url", module.path, index,
      MaxDescriptorStringBytes, false, totalBytes)
    if not supportUrl.isOk:
      return failure[PluginCatalog](move(supportUrl.error))
    var version = copyText(raw.version, "version", module.path, index,
      MaxDescriptorStringBytes, false, totalBytes)
    if not version.isOk:
      return failure[PluginCatalog](move(version.error))
    var description = copyText(raw.description, "description", module.path,
      index, MaxDescriptorStringBytes, false, totalBytes)
    if not description.isOk:
      return failure[PluginCatalog](move(description.error))
    var features = copyFeatures(raw.features, module.path, index, totalBytes)
    if not features.isOk:
      return failure[PluginCatalog](move(features.error))

    ids.incl(id.value)
    descriptors.add(PluginDescriptor(
      index: index,
      id: move(id.value),
      name: move(name.value),
      vendor: move(vendor.value),
      url: move(url.value),
      manualUrl: move(manualUrl.value),
      supportUrl: move(supportUrl.value),
      version: move(version.value),
      description: move(description.value),
      features: move(features.value),
    ))

  success(PluginCatalog(
    canonicalPath: module.path,
    descriptors: move(descriptors),
  ))

proc loadCatalog*(path: string): Result[PluginCatalog] =
  var opened = openClapModule(path)
  if not opened.isOk:
    return failure[PluginCatalog](move(opened.error))
  var module = move(opened.value)

  var catalog = module.readCatalog()
  var cleanup = module.close()
  if not catalog.isOk:
    if cleanup.isOk:
      return failure[PluginCatalog](move(catalog.error))
    return failure[PluginCatalog](mergeCleanupError(
      catalog.error, cleanup.error))
  if not cleanup.isOk:
    return failure[PluginCatalog](move(cleanup.error))
  success(move(catalog.value))
