import std/[os, strutils]

import ../domain/[errors, result]
import ../platform/linux/dynlib
import ./[ffi, uid]

const
  Vst3ArchitectureDir* = "x86_64-linux"
  MaxVst3Classes* = 4_096
  ElfHeaderBytes = 20
  ElfClass64 = 2'u8
  ElfDataLittleEndian = 1'u8
  ElfVersionCurrent = 1'u8
  ElfMachineX86_64 = 62'u16

type
  Vst3FactoryLevel* = enum
    vflBase = "base"
    vflV2 = "v2"
    vflV3 = "v3"

  Vst3ClassRecord* = object
    index*: int
    cid*: Vst3Tuid
    category*: string
    name*: string
    subCategories*: string
    vendor*: string
    version*: string
    sdkVersion*: string

  Vst3FactoryCatalog* = object
    vendor*: string
    url*: string
    email*: string
    factoryLevel*: Vst3FactoryLevel
    classes*: seq[Vst3ClassRecord]

  Vst3FactoryView = object
    objectPointer: pointer
    level: Vst3FactoryLevel
    ownsReference: bool

  Vst3Module* = object
    ## Move-only owner for one initialized VST3 module and its factory.
    library: DynamicLibrary
    bundlePath: string
    binaryPath: string
    moduleEntry: Vst3ModuleEntry
    moduleExit: Vst3ModuleExit
    getPluginFactory: Vst3GetPluginFactory
    factory: ptr Vst3PluginFactory
    entryInvoked: bool
    entryAccepted: bool

proc `=destroy`*(module: var Vst3Module) =
  `=destroy`(module.library)
  `=destroy`(module.bundlePath)
  `=destroy`(module.binaryPath)

proc `=copy`*(destination: var Vst3Module; source: Vst3Module) {.error:
  "Vst3Module owns foreign resources and cannot be copied; use move".}
proc `=dup`*(source: Vst3Module): Vst3Module {.error:
  "Vst3Module owns foreign resources and cannot be duplicated; use move".}

proc `=sink`*(destination: var Vst3Module; source: Vst3Module) =
  doAssert not destination.library.isOpen and not destination.entryInvoked,
    "an open Vst3Module must be closed before move assignment"
  `=sink`(destination.library, source.library)
  `=sink`(destination.bundlePath, source.bundlePath)
  `=sink`(destination.binaryPath, source.binaryPath)
  destination.moduleEntry = source.moduleEntry
  destination.moduleExit = source.moduleExit
  destination.getPluginFactory = source.getPluginFactory
  destination.factory = source.factory
  destination.entryInvoked = source.entryInvoked
  destination.entryAccepted = source.entryAccepted

proc vst3Error(kind: HostErrorKind; message, path: string;
               detail = ""): HostError =
  var context = "bundle=" & path
  if detail.len > 0:
    context.add("; " & detail)
  hostError(hsVst3, kind, message, context)

proc wrapLoaderError(kind: HostErrorKind; message, path: string;
                     error: HostError): HostError =
  vst3Error(kind, message, path, error.context)

proc bundlePath*(module: Vst3Module): string {.inline.} =
  module.bundlePath

proc binaryPath*(module: Vst3Module): string {.inline.} =
  module.binaryPath

proc isOpen*(module: Vst3Module): bool {.inline.} =
  module.library.isOpen

proc isEntryInvoked*(module: Vst3Module): bool {.inline.} =
  module.entryInvoked

proc isEntryAccepted*(module: Vst3Module): bool {.inline.} =
  module.entryAccepted

proc validateElf(path: string): Result[Unit] =
  var file: File
  var opened = false
  try:
    file = open(path, fmRead)
    opened = true
    var header: array[ElfHeaderBytes, uint8]
    if file.readBuffer(addr header[0], header.len) != header.len:
      return failure[Unit](vst3Error(
        hekVst3Binary,
        "VST3 module binary has a truncated ELF header",
        path,
      ))
    if header[0] != 0x7F'u8 or header[1] != uint8(ord('E')) or
        header[2] != uint8(ord('L')) or header[3] != uint8(ord('F')):
      return failure[Unit](vst3Error(
        hekVst3Binary,
        "VST3 module binary is not an ELF file",
        path,
      ))
    if header[4] != ElfClass64 or header[5] != ElfDataLittleEndian or
        header[6] != ElfVersionCurrent:
      return failure[Unit](vst3Error(
        hekVst3Binary,
        "VST3 module binary has an unsupported ELF class or encoding",
        path,
        "class=" & $header[4] & "; data=" & $header[5] &
          "; version=" & $header[6],
      ))
    let machine = uint16(header[18]) or (uint16(header[19]) shl 8)
    if machine != ElfMachineX86_64:
      return failure[Unit](vst3Error(
        hekVst3Binary,
        "VST3 module binary has an unsupported ELF machine",
        path,
        "machine=" & $machine,
      ))
    success()
  except CatchableError as error:
    failure[Unit](vst3Error(
      hekVst3Binary,
      "could not inspect VST3 module ELF header",
      path,
      error.msg,
    ))
  finally:
    if opened:
      close(file)

proc selectBinary(bundlePath: string): Result[string] =
  let split = splitFile(bundlePath)
  let bundleName = split.name
  let architecturePath = bundlePath / "Contents" / Vst3ArchitectureDir
  if not dirExists(architecturePath):
    return failure[string](vst3Error(
      hekVst3Binary,
      "VST3 bundle has no supported Linux architecture directory",
      bundlePath,
      "expected=" & architecturePath,
    ))

  let binary = architecturePath / (bundleName & ".so")
  if not fileExists(binary):
    return failure[string](vst3Error(
      hekVst3Binary,
      "VST3 bundle is missing its same-stem Linux module binary",
      bundlePath,
      "expected=" & binary,
    ))
  var elf = validateElf(binary)
  if not elf.isOk:
    return failure[string](move(elf.error))
  success(binary)

proc cleanupError(primary, cleanup: HostError): HostError =
  result = cleanup
  result.context.add("; primary=" & primary.message)
  if primary.context.len > 0:
    result.context.add(" (" & primary.context & ")")

proc close*(module: var Vst3Module): Result[Unit] =
  var firstFailure: HostError

  if module.factory != nil:
    let factory = module.factory
    if factory.lpVtbl == nil or factory.lpVtbl.release == nil:
      firstFailure = vst3Error(
        hekVst3Factory,
        "VST3 factory has no release callback",
        module.bundlePath,
      )
    else:
      discard factory.lpVtbl.release(cast[pointer](factory))
    module.factory = nil

  if module.entryInvoked:
    if module.moduleExit == nil:
      if firstFailure.message.len == 0:
        firstFailure = vst3Error(
          hekVst3Unload,
          "VST3 module entry was invoked without ModuleExit",
          module.bundlePath,
        )
    elif not module.moduleExit():
      if firstFailure.message.len == 0:
        firstFailure = vst3Error(
          hekVst3Unload,
          "VST3 ModuleExit reported failure",
          module.bundlePath,
        )
    module.entryInvoked = false
    module.entryAccepted = false

  module.moduleEntry = nil
  module.moduleExit = nil
  module.getPluginFactory = nil

  let closed = module.library.close()
  if not closed.isOk and firstFailure.message.len == 0:
    firstFailure = wrapLoaderError(
      hekVst3Unload,
      "could not unload VST3 module",
      module.bundlePath,
      closed.error,
    )

  if firstFailure.message.len > 0:
    return failure[Unit](move(firstFailure))
  success()

proc rollback(module: var Vst3Module; primary: HostError): HostError =
  let cleanup = module.close()
  if cleanup.isOk:
    primary
  else:
    cleanupError(primary, cleanup.error)

proc openVst3Module*(path: string; keepLoaded = true): Result[Vst3Module] =
  if path.len == 0:
    return failure[Vst3Module](vst3Error(
      hekVst3Path, "VST3 bundle path must not be empty", path))
  if not dirExists(path) or not path.toLowerAscii.endsWith(".vst3"):
    return failure[Vst3Module](vst3Error(
      hekVst3Path,
      "VST3 path must be a .vst3 bundle directory",
      path,
    ))

  var canonicalPath: string
  try:
    canonicalPath = expandFilename(path)
  except OSError as error:
    return failure[Vst3Module](vst3Error(
      hekVst3Path, "could not resolve VST3 bundle path", path, error.msg))
  except ValueError as error:
    return failure[Vst3Module](vst3Error(
      hekVst3Path, "could not resolve VST3 bundle path", path, error.msg))

  var binary = selectBinary(canonicalPath)
  if not binary.isOk:
    return failure[Vst3Module](move(binary.error))

  var opened = openDynamicLibrary(binary.value, keepLoaded)
  if not opened.isOk:
    return failure[Vst3Module](wrapLoaderError(
      hekVst3Binary, "could not load VST3 module binary", canonicalPath,
      opened.error))

  var module = Vst3Module(
    library: move(opened.value),
    bundlePath: canonicalPath,
    binaryPath: binary.value,
  )

  let entry = resolveSymbol[Vst3ModuleEntry](module.library, "ModuleEntry")
  if not entry.isOk:
    return failure[Vst3Module](module.rollback(wrapLoaderError(
      hekVst3Symbol, "VST3 ModuleEntry symbol is unavailable", canonicalPath,
      entry.error)))
  module.moduleEntry = entry.value

  let exit = resolveSymbol[Vst3ModuleExit](module.library, "ModuleExit")
  if not exit.isOk:
    return failure[Vst3Module](module.rollback(wrapLoaderError(
      hekVst3Symbol, "VST3 ModuleExit symbol is unavailable", canonicalPath,
      exit.error)))
  module.moduleExit = exit.value

  let factorySymbol = resolveSymbol[Vst3GetPluginFactory](
    module.library, "GetPluginFactory")
  if not factorySymbol.isOk:
    return failure[Vst3Module](module.rollback(wrapLoaderError(
      hekVst3Symbol, "VST3 GetPluginFactory symbol is unavailable",
      canonicalPath, factorySymbol.error)))
  module.getPluginFactory = factorySymbol.value

  module.entryInvoked = true
  module.entryAccepted = module.moduleEntry(module.library.nativeHandle)
  if not module.entryAccepted:
    return failure[Vst3Module](module.rollback(vst3Error(
      hekVst3Entry, "VST3 ModuleEntry rejected the module", canonicalPath)))

  module.factory = module.getPluginFactory()
  if module.factory == nil or module.factory.lpVtbl == nil:
    return failure[Vst3Module](module.rollback(vst3Error(
      hekVst3Factory, "VST3 GetPluginFactory returned no factory", canonicalPath)))
  if module.factory.lpVtbl.queryInterface == nil or
      module.factory.lpVtbl.release == nil or
      module.factory.lpVtbl.getFactoryInfo == nil or
      module.factory.lpVtbl.countClasses == nil or
      module.factory.lpVtbl.getClassInfo == nil or
      module.factory.lpVtbl.createInstance == nil:
    return failure[Vst3Module](module.rollback(vst3Error(
      hekVst3Factory,
      "VST3 factory is missing a required callback",
      canonicalPath,
    )))

  success(move(module))

proc createInstance*(module: Vst3Module; classId, interfaceId: Vst3Tuid):
    Result[pointer] =
  if not module.isOpen or module.factory == nil or module.factory.lpVtbl == nil or
      module.factory.lpVtbl.createInstance == nil:
    return failure[pointer](vst3Error(
      hekVst3Factory, "VST3 module is not ready for instance creation",
      module.bundlePath))
  var objectPointer: pointer = nil
  let code = module.factory.lpVtbl.createInstance(
    cast[pointer](module.factory), cast[cstring](unsafeAddr classId[0]),
    cast[cstring](unsafeAddr interfaceId[0]), addr objectPointer)
  if code != Vst3ResultOk or objectPointer == nil:
    if objectPointer != nil:
      let base = cast[ptr Vst3FUnknown](objectPointer)
      if base.lpVtbl != nil and base.lpVtbl.release != nil:
        discard base.lpVtbl.release(objectPointer)
    return failure[pointer](vst3Error(
      hekVst3Factory, "VST3 factory could not create the requested instance",
      module.bundlePath, "result=" & $code))
  success(objectPointer)

proc queryOptionalFactory(module: Vst3Module; iidText: string): Result[pointer] =
  var iidResult = parseVst3Uid(iidText)
  if not iidResult.isOk:
    return failure[pointer](move(iidResult.error))
  var objectPointer: pointer = nil
  let code = module.factory.lpVtbl.queryInterface(
    cast[pointer](module.factory), addr iidResult.value, addr objectPointer)
  if code == Vst3NoInterface:
    return success(pointer(nil))
  if code != Vst3ResultOk:
    return failure[pointer](vst3Error(
      hekVst3Factory,
      "VST3 factory interface query failed",
      module.bundlePath,
      "iid=" & iidText & "; result=" & $code,
    ))
  if objectPointer == nil:
    return failure[pointer](vst3Error(
      hekVst3Factory,
      "VST3 factory interface query returned a null object",
      module.bundlePath,
      "iid=" & iidText,
    ))
  success(objectPointer)

proc validFactoryView(view: Vst3FactoryView): bool
proc releaseQueriedFactory(view: var Vst3FactoryView)

proc acquireFactoryView(module: Vst3Module): Result[Vst3FactoryView] =
  var v3 = queryOptionalFactory(module, Vst3Factory3Iid)
  if not v3.isOk:
    return failure[Vst3FactoryView](move(v3.error))
  if v3.value != nil:
    var view = Vst3FactoryView(
      objectPointer: v3.value, level: vflV3, ownsReference: true)
    if not view.validFactoryView():
      view.releaseQueriedFactory()
      return failure[Vst3FactoryView](vst3Error(
        hekVst3Factory,
        "VST3 queried factory interface is missing required callbacks",
        module.bundlePath, "level=v3"))
    return success(view)

  var v2 = queryOptionalFactory(module, Vst3Factory2Iid)
  if not v2.isOk:
    return failure[Vst3FactoryView](move(v2.error))
  if v2.value != nil:
    var view = Vst3FactoryView(
      objectPointer: v2.value, level: vflV2, ownsReference: true)
    if not view.validFactoryView():
      view.releaseQueriedFactory()
      return failure[Vst3FactoryView](vst3Error(
        hekVst3Factory,
        "VST3 queried factory interface is missing required callbacks",
        module.bundlePath, "level=v2"))
    return success(view)

  let view = Vst3FactoryView(
    objectPointer: cast[pointer](module.factory), level: vflBase,
    ownsReference: false)
  if not view.validFactoryView():
    return failure[Vst3FactoryView](vst3Error(
      hekVst3Factory,
      "VST3 base factory interface is missing required callbacks",
      module.bundlePath, "level=base"))
  success(view)
proc factoryVtable(view: Vst3FactoryView): ptr Vst3PluginFactoryVtbl =
  case view.level
  of vflBase:
    cast[ptr Vst3PluginFactory](view.objectPointer).lpVtbl
  of vflV2:
    cast[ptr Vst3PluginFactoryVtbl](
      cast[ptr Vst3PluginFactory2](view.objectPointer).lpVtbl)
  of vflV3:
    cast[ptr Vst3PluginFactoryVtbl](
      cast[ptr Vst3PluginFactory3](view.objectPointer).lpVtbl)

proc factoryVtable2(view: Vst3FactoryView): ptr Vst3PluginFactory2Vtbl =
  case view.level
  of vflBase:
    nil
  of vflV2:
    cast[ptr Vst3PluginFactory2](view.objectPointer).lpVtbl
  of vflV3:
    cast[ptr Vst3PluginFactory2Vtbl](
      cast[ptr Vst3PluginFactory3](view.objectPointer).lpVtbl)

proc factoryVtable3(view: Vst3FactoryView): ptr Vst3PluginFactory3Vtbl =
  if view.level != vflV3:
    return nil
  cast[ptr Vst3PluginFactory3](view.objectPointer).lpVtbl

proc validFactoryView(view: Vst3FactoryView): bool =
  if view.objectPointer == nil:
    return false
  let base = view.factoryVtable()
  if base == nil or base.queryInterface == nil or base.addRef == nil or
      base.release == nil or base.getFactoryInfo == nil or
      base.countClasses == nil or base.getClassInfo == nil or
      base.createInstance == nil:
    return false
  case view.level
  of vflBase:
    true
  of vflV2:
    let extended = view.factoryVtable2()
    extended != nil and extended.getClassInfo2 != nil
  of vflV3:
    let extended = view.factoryVtable2()
    let unicode = view.factoryVtable3()
    extended != nil and extended.getClassInfo2 != nil and unicode != nil

proc releaseQueriedFactory(view: var Vst3FactoryView) =
  if not view.ownsReference:
    return
  let base = view.factoryVtable()
  if base != nil and base.release != nil:
    discard base.release(view.objectPointer)
  view.ownsReference = false

proc appendUtf8(output: var string; codepoint: uint32) =
  if codepoint <= 0x7F'u32:
    output.add(char(codepoint))
  elif codepoint <= 0x7FF'u32:
    output.add(char(0xC0'u32 or (codepoint shr 6)))
    output.add(char(0x80'u32 or (codepoint and 0x3F'u32)))
  elif codepoint <= 0xFFFF'u32:
    output.add(char(0xE0'u32 or (codepoint shr 12)))
    output.add(char(0x80'u32 or ((codepoint shr 6) and 0x3F'u32)))
    output.add(char(0x80'u32 or (codepoint and 0x3F'u32)))
  else:
    output.add(char(0xF0'u32 or (codepoint shr 18)))
    output.add(char(0x80'u32 or ((codepoint shr 12) and 0x3F'u32)))
    output.add(char(0x80'u32 or ((codepoint shr 6) and 0x3F'u32)))
    output.add(char(0x80'u32 or (codepoint and 0x3F'u32)))
proc fixedUtf16Result(value: openArray[uint16]): Result[string] =
  var output = newStringOfCap(value.len)
  var index = 0
  while index < value.len and value[index] != 0'u16:
    let unit = uint32(value[index])
    var codepoint = unit
    if unit >= 0xD800'u32 and unit <= 0xDBFF'u32:
      if index + 1 < value.len:
        let low = uint32(value[index + 1])
        if low >= 0xDC00'u32 and low <= 0xDFFF'u32:
          codepoint = 0x10000'u32 + ((unit - 0xD800'u32) shl 10) +
            (low - 0xDC00'u32)
          inc index
        else:
          codepoint = 0xFFFD'u32
      else:
        codepoint = 0xFFFD'u32
    elif unit >= 0xDC00'u32 and unit <= 0xDFFF'u32:
      codepoint = 0xFFFD'u32
    appendUtf8(output, codepoint)
    inc index
  if index == value.len:
    return failure[string](hostError(
      hsVst3, hekVst3Descriptor,
      "VST3 UTF-16 metadata is not NUL terminated"))
  success(move(output))
proc releaseFactoryView(module: Vst3Module; view: var Vst3FactoryView): Result[Unit] =
  if not view.ownsReference:
    return success()
  let vtable = factoryVtable(view)
  if vtable == nil or vtable.release == nil:
    return failure[Unit](vst3Error(
      hekVst3Factory,
      "VST3 queried factory interface has no release callback",
      module.bundlePath,
      "level=" & $view.level,
    ))
  discard vtable.release(view.objectPointer)
  view.ownsReference = false
  success()

proc factoryInfo(module: Vst3Module; view: Vst3FactoryView;
                 info: var Vst3FactoryInfo): Result[Unit] =
  let vtable = factoryVtable(view)
  if vtable.getFactoryInfo(view.objectPointer, addr info) != Vst3ResultOk:
    return failure[Unit](vst3Error(
      hekVst3Factory, "VST3 factory information query failed",
      module.bundlePath, "level=" & $view.level))
  success()

proc classCount(module: Vst3Module; view: Vst3FactoryView): Result[int32] =
  let vtable = factoryVtable(view)
  let count = vtable.countClasses(view.objectPointer)
  if count < 0 or count > MaxVst3Classes:
    return failure[int32](vst3Error(
      hekVst3Factory, "VST3 factory class count is outside the bound",
      module.bundlePath, "level=" & $view.level & "; count=" & $count))
  success(count)

proc classRecord(module: Vst3Module; view: Vst3FactoryView;
                 index: int32): Result[Vst3ClassRecord] =
  let vtable = factoryVtable(view)
  var record = Vst3ClassRecord(index: int(index))
  if view.level == vflBase:
    var info: Vst3ClassInfo
    if vtable.getClassInfo(view.objectPointer, index, addr info) != Vst3ResultOk:
      return failure[Vst3ClassRecord](vst3Error(
        hekVst3Descriptor, "VST3 class information query failed",
        module.bundlePath, "index=" & $index))
    record.cid = info.cid
    var category = fixedCStringResult(info.category)
    var name = fixedCStringResult(info.name)
    if not category.isOk or not name.isOk:
      return failure[Vst3ClassRecord](vst3Error(
        hekVst3Descriptor,
        "VST3 class metadata contains malformed fixed-width text",
        module.bundlePath, "index=" & $index))
    record.category = category.value
    record.name = name.value
    return success(record)

  if view.level == vflV3:
    let v3table = factoryVtable3(view)
    if v3table != nil and v3table.getClassInfoUnicode != nil:
      var info: Vst3ClassInfoW
      if v3table.getClassInfoUnicode(
          view.objectPointer, index, addr info) == Vst3ResultOk:
        record.cid = info.cid
        var category = fixedCStringResult(info.category)
        var name = fixedUtf16Result(info.name)
        var subCategories = fixedCStringResult(info.subCategories)
        var vendor = fixedUtf16Result(info.vendor)
        var version = fixedUtf16Result(info.version)
        var sdkVersion = fixedUtf16Result(info.sdkVersion)
        if not category.isOk or not name.isOk or not subCategories.isOk or
            not vendor.isOk or not version.isOk or not sdkVersion.isOk:
          return failure[Vst3ClassRecord](vst3Error(
            hekVst3Descriptor,
            "VST3 Unicode class metadata is malformed",
            module.bundlePath, "index=" & $index))
        record.category = category.value
        record.name = name.value
        record.subCategories = subCategories.value
        record.vendor = vendor.value
        record.version = version.value
        record.sdkVersion = sdkVersion.value
        return success(record)

  let v2table = factoryVtable2(view)
  var info: Vst3ClassInfo2
  if v2table.getClassInfo2(view.objectPointer, index, addr info) != Vst3ResultOk:
    return failure[Vst3ClassRecord](vst3Error(
      hekVst3Descriptor, "VST3 extended class information query failed",
      module.bundlePath, "index=" & $index & "; level=" & $view.level))
  record.cid = info.cid
  var category = fixedCStringResult(info.category)
  var name = fixedCStringResult(info.name)
  var subCategories = fixedCStringResult(info.subCategories)
  var vendor = fixedCStringResult(info.vendor)
  var version = fixedCStringResult(info.version)
  var sdkVersion = fixedCStringResult(info.sdkVersion)
  if not category.isOk or not name.isOk or not subCategories.isOk or
      not vendor.isOk or not version.isOk or not sdkVersion.isOk:
    return failure[Vst3ClassRecord](vst3Error(
      hekVst3Descriptor,
      "VST3 extended class metadata contains malformed fixed-width text",
      module.bundlePath, "index=" & $index & "; level=" & $view.level))
  record.category = category.value
  record.name = name.value
  record.subCategories = subCategories.value
  record.vendor = vendor.value
  record.version = version.value
  record.sdkVersion = sdkVersion.value
  success(record)

proc readFactoryCatalog*(module: Vst3Module): Result[Vst3FactoryCatalog] =
  if not module.isOpen or not module.entryAccepted or module.factory == nil:
    return failure[Vst3FactoryCatalog](vst3Error(
      hekVst3Factory, "VST3 module is not ready for factory access",
      module.bundlePath))

  var viewResult = acquireFactoryView(module)
  if not viewResult.isOk:
    return failure[Vst3FactoryCatalog](move(viewResult.error))
  var view = move(viewResult.value)

  var info: Vst3FactoryInfo
  var infoResult = factoryInfo(module, view, info)
  if not infoResult.isOk:
    discard releaseFactoryView(module, view)
    return failure[Vst3FactoryCatalog](move(infoResult.error))

  var countResult = classCount(module, view)
  if not countResult.isOk:
    discard releaseFactoryView(module, view)
    return failure[Vst3FactoryCatalog](move(countResult.error))

  var vendor = fixedCStringResult(info.vendor)
  var url = fixedCStringResult(info.url)
  var email = fixedCStringResult(info.email)
  if not vendor.isOk or not url.isOk or not email.isOk:
    discard releaseFactoryView(module, view)
    return failure[Vst3FactoryCatalog](vst3Error(
      hekVst3Descriptor,
      "VST3 factory metadata contains malformed fixed-width text",
      module.bundlePath))

  var catalog = Vst3FactoryCatalog(
    vendor: vendor.value,
    url: url.value,
    email: email.value,
    factoryLevel: view.level,
    classes: newSeqOfCap[Vst3ClassRecord](countResult.value),
  )
  for index in 0 ..< countResult.value:
    var record = classRecord(module, view, index)
    if not record.isOk:
      discard releaseFactoryView(module, view)
      return failure[Vst3FactoryCatalog](move(record.error))
    catalog.classes.add(record.value)

  var released = releaseFactoryView(module, view)
  if not released.isOk:
    return failure[Vst3FactoryCatalog](move(released.error))
  success(move(catalog))

proc setFactoryHostContext*(module: Vst3Module; context: pointer): Result[Unit] =
  if context == nil:
    return failure[Unit](vst3Error(
      hekVst3Factory, "VST3 host context must not be null", module.bundlePath))
  var viewResult = acquireFactoryView(module)
  if not viewResult.isOk:
    return failure[Unit](move(viewResult.error))
  var view = move(viewResult.value)
  if view.level != vflV3:
    discard releaseFactoryView(module, view)
    return failure[Unit](vst3Error(
      hekVst3Factory, "VST3 factory does not expose IPluginFactory3",
      module.bundlePath))
  let vtable = cast[ptr Vst3PluginFactory3](view.objectPointer).lpVtbl
  if vtable.setHostContext == nil:
    discard releaseFactoryView(module, view)
    return failure[Unit](vst3Error(
      hekVst3Factory, "VST3 factory has no setHostContext callback",
      module.bundlePath))
  let code = vtable.setHostContext(view.objectPointer, context)
  var released = releaseFactoryView(module, view)
  if code != Vst3ResultOk and code != Vst3NotImplemented and
      code != Vst3ResultFalse:
    return failure[Unit](vst3Error(
      hekVst3Factory, "VST3 factory rejected the host context",
      module.bundlePath, "result=" & $code))
  if not released.isOk:
    return failure[Unit](move(released.error))
  success()
