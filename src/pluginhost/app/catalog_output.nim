import std/json

import ../domain/plugin_catalog
import ../support/utf8

proc renderDescriptorHuman(descriptor: PluginDescriptor): string =
  result = "[" & $descriptor.index & "] " &
    escapeControlText(descriptor.name) & "\n"
  result.add("  ID: " & escapeControlText(descriptor.id) & "\n")
  result.add("  Vendor: " & escapeControlText(descriptor.vendor) & "\n")
  result.add("  Version: " & escapeControlText(descriptor.version) & "\n")
  result.add("  Features: ")
  for index, feature in descriptor.features:
    if index > 0:
      result.add(", ")
    result.add(escapeControlText(feature))
  result.add("\n")

proc renderCatalogHuman*(catalog: PluginCatalog): string =
  if catalog.descriptors.len == 0:
    return "No CLAP plugin descriptors found.\n"
  for index, descriptor in catalog.descriptors:
    if index > 0:
      result.add("\n")
    result.add(renderDescriptorHuman(descriptor))

proc descriptorJson(descriptor: PluginDescriptor): JsonNode =
  result = newJObject()
  result["index"] = %descriptor.index
  result["id"] = %descriptor.id
  result["name"] = %descriptor.name
  result["vendor"] = %descriptor.vendor
  result["version"] = %descriptor.version
  result["features"] = %descriptor.features

proc renderCatalogJson*(catalog: PluginCatalog): string =
  var plugins = newJArray()
  for descriptor in catalog.descriptors:
    plugins.add(descriptorJson(descriptor))

  var root = newJObject()
  root["path"] = %replaceInvalidUtf8(catalog.canonicalPath)
  root["plugins"] = plugins
  $root & "\n"
