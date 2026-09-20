import std/[os, sets, strutils]

import ../domain/[errors, plugin_catalog, result]
import ./[ffi, module, uid]

proc catalogCleanupError(primary, cleanup: HostError): HostError =
  result = cleanup
  result.context.add("; primary=" & primary.message)
  if primary.context.len > 0:
    result.context.add(" (" & primary.context & ")")

proc classFeatures(subCategories: string): seq[string] =
  for value in subCategories.split({',', '|'}):
    let feature = value.strip()
    if feature.len > 0:
      result.add(feature)

proc loadVst3Catalog*(path: string): Result[PluginCatalog] =
  var opened = openVst3Module(path)
  if not opened.isOk:
    return failure[PluginCatalog](move(opened.error))
  var module = move(opened.value)

  var raw = module.readFactoryCatalog()
  var cleanup = module.close()
  if not raw.isOk:
    if cleanup.isOk:
      return failure[PluginCatalog](move(raw.error))
    return failure[PluginCatalog](catalogCleanupError(raw.error, cleanup.error))
  if not cleanup.isOk:
    return failure[PluginCatalog](move(cleanup.error))

  var descriptors: seq[PluginDescriptor] = @[]
  var seenCids = initHashSet[string]()
  for classInfo in raw.value.classes:
    if classInfo.category != Vst3AudioEffectClass:
      continue
    let id = formatVst3Uid(classInfo.cid)
    if id in seenCids:
      return failure[PluginCatalog](hostError(
        hsVst3,
        hekVst3Descriptor,
        "VST3 bundle contains duplicate processor class identifiers",
        "path=" & expandFilename(path) & "; cid=" & id,
      ))
    seenCids.incl(id)
    let vendor = if classInfo.vendor.len > 0:
        classInfo.vendor
      else:
        raw.value.vendor
    let version = classInfo.version
    descriptors.add(PluginDescriptor(
      format: pfVst3,
      index: descriptors.len,
      nativeIndex: classInfo.index,
      id: id,
      name: classInfo.name,
      vendor: vendor,
      url: raw.value.url,
      version: version,
      features: classFeatures(classInfo.subCategories),
    ))

  success(PluginCatalog(
    canonicalPath: expandFilename(path),
    descriptors: move(descriptors),
  ))
