import std/strutils

import ./[errors, result]

type
  PluginSelectorKind* = enum
    pskImplicitSingle
    pskId
    pskIndex

  PluginSelector* = object
    case kind*: PluginSelectorKind
    of pskImplicitSingle:
      discard
    of pskId:
      pluginId*: string
    of pskIndex:
      pluginIndex*: int

  PluginDescriptor* = object
    index*: int
    id*: string
    name*: string
    vendor*: string
    url*: string
    manualUrl*: string
    supportUrl*: string
    version*: string
    description*: string
    features*: seq[string]

  PluginCatalog* = object
    canonicalPath*: string
    descriptors*: seq[PluginDescriptor]

proc availableDescriptors(catalog: PluginCatalog): string =
  var lines: seq[string]
  for descriptor in catalog.descriptors:
    lines.add("[" & $descriptor.index & "] " & descriptor.id &
      " (" & descriptor.name & ")")
  lines.join(", ")

proc selectionError(message: string; catalog: PluginCatalog;
                    context = ""): HostError =
  var detail = context
  let available = catalog.availableDescriptors()
  if available.len > 0:
    if detail.len > 0:
      detail.add("; ")
    detail.add("available=" & available)
  hostError(hsClap, hekPluginSelection, message, detail)

proc selectDescriptor*(catalog: PluginCatalog;
                       selector: PluginSelector): Result[PluginDescriptor] =
  case selector.kind
  of pskImplicitSingle:
    if catalog.descriptors.len == 1:
      return success(catalog.descriptors[0])
    if catalog.descriptors.len == 0:
      return failure[PluginDescriptor](selectionError(
        "plugin library contains no descriptors",
        catalog,
        catalog.canonicalPath,
      ))
    failure[PluginDescriptor](selectionError(
      "plugin selection is required for a library with multiple descriptors",
      catalog,
      catalog.canonicalPath,
    ))
  of pskId:
    for descriptor in catalog.descriptors:
      if descriptor.id == selector.pluginId:
        return success(descriptor)
    failure[PluginDescriptor](selectionError(
      "plugin ID was not found",
      catalog,
      "path=" & catalog.canonicalPath & "; id=" & selector.pluginId,
    ))
  of pskIndex:
    if selector.pluginIndex >= 0:
      for descriptor in catalog.descriptors:
        if descriptor.index == selector.pluginIndex:
          return success(descriptor)
    failure[PluginDescriptor](selectionError(
      "plugin index is out of range",
      catalog,
      "path=" & catalog.canonicalPath & "; index=" & $selector.pluginIndex,
    ))
