import std/[algorithm, os, posix, sets, strutils]

import ../clap/loader as clap_loader
import ../domain/[errors, plugin_catalog]
import ../vst3/catalog as vst3_catalog
import ./paths

type
  DiscoveredPlugin* = object
    ## One host-owned descriptor and the canonical library that provided it.
    path*: string
    descriptor*: PluginDescriptor

  DiscoveryIssue* = object
    ## A copied control-plane failure that did not stop the scan.
    path*: string
    error*: HostError

  ScanReport* = object
    plugins*: seq[DiscoveredPlugin]
    issues*: seq[DiscoveryIssue]

proc discoveryError(kind: HostErrorKind; message, path: string;
                    detail = ""): HostError =
  var context = "path=" & path
  if detail.len > 0:
    context.add("; " & detail)
  hostError(hsDiscovery, kind, message, context)

proc addIssue(report: var ScanReport; path: string; error: HostError) =
  report.issues.add(DiscoveryIssue(path: path, error: error))

proc rootFallbackPath(path: string): string =
  if path.len == 0:
    return path
  try:
    result = absolutePath(path)
    result.normalizePath()
  except ValueError:
    result = path

proc missingRootError(code: cint): bool =
  code == ENOENT or code == ENOTDIR

proc canonicalRoot(root: DiscoveryRoot; report: var ScanReport): string =
  if root.path.len == 0:
    report.addIssue(root.path, discoveryError(
      hekDiscoveryRoot,
      "discovery root is empty",
      root.path,
      "source=" & $root.kind,
    ))
    return

  try:
    let info = getFileInfo(root.path, followSymlink = true)
    if info.kind != pcDir:
      report.addIssue(root.path, discoveryError(
        hekDiscoveryRoot,
        "discovery root is not a directory",
        root.path,
        "source=" & $root.kind,
      ))
      return
    result = expandFilename(root.path)
  except OSError as error:
    let errorCode = errno
    if root.kind in {drkHome, drkSystem, drkVstHome, drkVstSystem,
        drkExecutable} and
        missingRootError(errorCode):
      return
    report.addIssue(root.path, discoveryError(
      hekDiscoveryRoot,
      "could not access discovery root",
      root.path,
      "source=" & $root.kind & "; detail=" & error.msg,
    ))
  except ValueError as error:
    report.addIssue(root.path, discoveryError(
      hekDiscoveryRoot,
      "could not canonicalize discovery root",
      root.path,
      "source=" & $root.kind & "; detail=" & error.msg,
    ))

proc isVst3Bundle(path: string): bool =
  path.toLowerAscii.endsWith(".vst3")

proc addCatalog(report: var ScanReport; canonicalPath: string;
                seenCandidates: var HashSet[string];
                seenPluginKeys: var HashSet[string]) =
  if canonicalPath in seenCandidates:
    return
  seenCandidates.incl(canonicalPath)

  let catalog = if isVst3Bundle(canonicalPath):
      vst3_catalog.loadVst3Catalog(canonicalPath)
    else:
      clap_loader.loadCatalog(canonicalPath)
  if not catalog.isOk:
    report.addIssue(canonicalPath, catalog.error)
    return

  for descriptor in catalog.value.descriptors:
    let pluginKey = $descriptor.format & ":" & descriptor.id
    if descriptor.format == pfVst3 and pluginKey in seenPluginKeys:
      continue
    if descriptor.format == pfVst3:
      seenPluginKeys.incl(pluginKey)
    report.plugins.add(DiscoveredPlugin(
      path: catalog.value.canonicalPath,
      descriptor: descriptor,
    ))

proc inspectCandidate(report: var ScanReport; candidatePath: string;
                      seenCandidates: var HashSet[string];
                      seenPluginKeys: var HashSet[string]) =
  let vst3 = isVst3Bundle(candidatePath)
  var canonicalPath: string
  try:
    let info = getFileInfo(candidatePath, followSymlink = true)
    if vst3:
      if info.kind != pcDir:
        return
    elif info.kind != pcFile or info.isSpecial:
      return
    canonicalPath = expandFilename(candidatePath)
  except OSError as error:
    report.addIssue(candidatePath, discoveryError(
      hekDiscoveryCandidate,
      "could not canonicalize plugin candidate",
      candidatePath,
      error.msg,
    ))
    return
  except ValueError as error:
    report.addIssue(candidatePath, discoveryError(
      hekDiscoveryCandidate,
      "could not canonicalize plugin candidate",
      candidatePath,
      error.msg,
    ))
    return

  addCatalog(report, canonicalPath, seenCandidates, seenPluginKeys)

proc walkDirectory(directory: string; report: var ScanReport;
                   seenCandidates: var HashSet[string];
                   seenPluginKeys: var HashSet[string]) =
  var entries: seq[tuple[kind: PathComponent, path: string]]
  try:
    for kind, path in walkDir(directory, checkDir = true):
      entries.add((kind, path))
  except OSError as error:
    report.addIssue(directory, discoveryError(
      hekDiscoveryTraversal,
      "could not read discovery directory",
      directory,
      error.msg,
    ))
    return

  entries.sort(proc(left, right: tuple[kind: PathComponent, path: string]): int =
    cmp(left.path, right.path))

  for entry in entries:
    case entry.kind
    of pcDir, pcLinkToDir:
      if isVst3Bundle(entry.path):
        inspectCandidate(report, entry.path, seenCandidates, seenPluginKeys)
      elif entry.kind == pcDir:
        walkDirectory(entry.path, report, seenCandidates, seenPluginKeys)
    of pcFile, pcLinkToFile:
      if entry.path.toLowerAscii.endsWith(".clap"):
        inspectCandidate(report, entry.path, seenCandidates, seenPluginKeys)

proc scanConfiguredRoots*(roots: openArray[DiscoveryRoot]): ScanReport =
  ## Scans already ordered roots; useful for deterministic callers and tests.
  var seenRoots = initHashSet[string]()
  var seenCandidates = initHashSet[string]()
  var seenPluginKeys = initHashSet[string]()

  for root in roots:
    let fallback = rootFallbackPath(root.path)
    if fallback.len > 0 and fallback in seenRoots:
      continue
    let canonical = canonicalRoot(root, result)
    if canonical.len == 0:
      if fallback.len > 0:
        seenRoots.incl(fallback)
      continue
    if canonical in seenRoots:
      continue
    seenRoots.incl(canonical)
    if isVst3Bundle(canonical):
      inspectCandidate(result, canonical, seenCandidates, seenPluginKeys)
    else:
      walkDirectory(canonical, result, seenCandidates, seenPluginKeys)

proc scanPlugins*(explicitRoots: openArray[string];
                  clapPath = getEnv("CLAP_PATH")): ScanReport =
  scanConfiguredRoots(discoveryRoots(explicitRoots, clapPath = clapPath))
