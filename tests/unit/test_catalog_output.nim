import std/[json, strutils, unittest]

import pluginhost/app/catalog_output
import pluginhost/domain/plugin_catalog

proc exampleCatalog(): PluginCatalog =
  PluginCatalog(
    canonicalPath: "/plugins/example.clap",
    descriptors: @[
      PluginDescriptor(
        index: 0,
        id: "org.example.synth",
        name: "Example Synth",
        vendor: "Example & Co.",
        version: "1.0\"beta",
        features: @["instrument", "stereo"],
      ),
    ],
  )

suite "plugin catalog rendering":
  test "human output reports all required descriptor fields":
    let rendered = renderCatalogHuman(exampleCatalog())

    check rendered.contains("[0] Example Synth")
    check rendered.contains("ID: org.example.synth")
    check rendered.contains("Vendor: Example & Co.")
    check rendered.contains("Version: 1.0\"beta")
    check rendered.contains("Features: instrument, stereo")
    check rendered.endsWith("\n")

  test "JSON output is one clean document with the reviewed schema":
    let rendered = renderCatalogJson(exampleCatalog())
    let parsed = parseJson(rendered)

    check rendered.endsWith("\n")
    check parsed.kind == JObject
    check parsed.len == 2
    check parsed["path"].getStr() == "/plugins/example.clap"
    check parsed["plugins"].len == 1
    let plugin = parsed["plugins"][0]
    check plugin.len == 6
    check plugin["index"].getInt() == 0
    check plugin["id"].getStr() == "org.example.synth"
    check plugin["name"].getStr() == "Example Synth"
    check plugin["vendor"].getStr() == "Example & Co."
    check plugin["version"].getStr() == "1.0\"beta"
    check plugin["features"][1].getStr() == "stereo"

  test "human output escapes plugin-provided control characters":
    var catalog = exampleCatalog()
    catalog.descriptors[0].name = "Unsafe\n\x1bName"
    catalog.descriptors[0].features = @["line\tbreak"]

    let rendered = renderCatalogHuman(catalog)

    check rendered.contains("Unsafe\\u000a\\u001bName")
    check rendered.contains("line\\u0009break")
    check not rendered.contains("Unsafe\n")

  test "an empty human catalog reports its state truthfully":
    check renderCatalogHuman(PluginCatalog()).contains("No CLAP")
