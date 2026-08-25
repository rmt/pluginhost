import std/json

import ../domain/plugin_catalog
import ../discovery/scanner
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

proc renderScanHuman*(report: ScanReport): string =
  if report.plugins.len == 0:
    return "No CLAP plugins found.\n"
  var lastPath = ""
  for plugin in report.plugins:
    if plugin.path != lastPath:
      if result.len > 0:
        result.add("\n")
      result.add("Path: " & escapeControlText(plugin.path) & "\n")
      lastPath = plugin.path
    result.add(renderDescriptorHuman(plugin.descriptor))

proc renderScanJson*(report: ScanReport): string =
  var plugins = newJArray()
  for plugin in report.plugins:
    var value = descriptorJson(plugin.descriptor)
    value["path"] = %replaceInvalidUtf8(plugin.path)
    plugins.add(value)

  var root = newJObject()
  root["plugins"] = plugins
  $root & "\n"
