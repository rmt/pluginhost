import std/[strutils, unittest]

import pluginhost/domain/[errors, plugin_catalog]

proc descriptor(index: int; id, name: string): PluginDescriptor =
  PluginDescriptor(index: index, id: id, name: name)

suite "host-owned plugin catalog selection":
  test "implicit selection accepts exactly one descriptor":
    let catalog = PluginCatalog(
      canonicalPath: "/plugins/one.clap",
      descriptors: @[descriptor(0, "org.example.one", "One")],
    )

    let selected = catalog.selectDescriptor(
      PluginSelector(kind: pskImplicitSingle))

    check selected.isOk
    check selected.value.id == "org.example.one"

  test "implicit selection rejects empty and ambiguous catalogs":
    let empty = PluginCatalog(canonicalPath: "/plugins/empty.clap")
    let multiple = PluginCatalog(
      canonicalPath: "/plugins/multiple.clap",
      descriptors: @[
        descriptor(0, "org.example.one", "One"),
        descriptor(1, "org.example.two", "Two"),
      ],
    )

    let emptySelection = empty.selectDescriptor(
      PluginSelector(kind: pskImplicitSingle))
    let ambiguous = multiple.selectDescriptor(
      PluginSelector(kind: pskImplicitSingle))

    check not emptySelection.isOk
    check emptySelection.error.kind == hekPluginSelection
    check emptySelection.error.exitCode() == ExitUsage
    check not ambiguous.isOk
    check ambiguous.error.context.contains("org.example.one")
    check ambiguous.error.context.contains("org.example.two")

  test "selection uses exact ID and zero-based descriptor index":
    let catalog = PluginCatalog(
      canonicalPath: "/plugins/multiple.clap",
      descriptors: @[
        descriptor(0, "org.example.one", "One"),
        descriptor(1, "org.example.two", "Two"),
      ],
    )

    let byId = catalog.selectDescriptor(PluginSelector(
      kind: pskId,
      pluginId: "org.example.two",
    ))
    let byIndex = catalog.selectDescriptor(PluginSelector(
      kind: pskIndex,
      pluginIndex: 0,
    ))

    check byId.isOk
    check byId.value.index == 1
    check byIndex.isOk
    check byIndex.value.id == "org.example.one"

  test "missing IDs and invalid indices are typed usage failures":
    let catalog = PluginCatalog(
      canonicalPath: "/plugins/one.clap",
      descriptors: @[descriptor(0, "org.example.one", "One")],
    )

    let missingId = catalog.selectDescriptor(PluginSelector(
      kind: pskId,
      pluginId: "ORG.EXAMPLE.ONE",
    ))
    let negative = catalog.selectDescriptor(PluginSelector(
      kind: pskIndex,
      pluginIndex: -1,
    ))
    let pastEnd = catalog.selectDescriptor(PluginSelector(
      kind: pskIndex,
      pluginIndex: 1,
    ))

    check not missingId.isOk
    check missingId.error.subsystem == hsClap
    check not negative.isOk
    check not pastEnd.isOk
