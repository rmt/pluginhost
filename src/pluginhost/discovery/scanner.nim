import std/[algorithm, os, sets, strutils]

import ../clap/loader
import ../domain/[errors, plugin_catalog]
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

proc rootUnavailable(root: DiscoveryRoot): bool =
  ## A failed lstat means the root is absent. For standard roots this is the
  ## documented harmless case; explicit and CLAP_PATH roots remain reportable.
  try:
    discard getFileInfo(root.path, followSymlink = false)
    false
  except OSError:
    true

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
    if root.kind in {drkHome, drkSystem} and rootUnavailable(root):
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

proc addCatalog(report: var ScanReport; canonicalPath: string;
                seenCandidates: var HashSet[string]) =
  if canonicalPath in seenCandidates:
    return
  seenCandidates.incl(canonicalPath)

  let catalog = loadCatalog(canonicalPath)
  if not catalog.isOk:
    report.addIssue(canonicalPath, catalog.error)
    return

  for descriptor in catalog.value.descriptors:
    report.plugins.add(DiscoveredPlugin(
      path: catalog.value.canonicalPath,
      descriptor: descriptor,
    ))

proc inspectCandidate(report: var ScanReport; candidatePath: string;
                      seenCandidates: var HashSet[string]) =
  var canonicalPath: string
  try:
    let info = getFileInfo(candidatePath, followSymlink = true)
    if info.kind != pcFile or info.isSpecial:
      return
    canonicalPath = expandFilename(candidatePath)
  except OSError as error:
    report.addIssue(candidatePath, discoveryError(
      hekDiscoveryCandidate,
      "could not canonicalize CLAP candidate",
      candidatePath,
      error.msg,
    ))
    return
  except ValueError as error:
    report.addIssue(candidatePath, discoveryError(
      hekDiscoveryCandidate,
      "could not canonicalize CLAP candidate",
      candidatePath,
      error.msg,
    ))
    return

  addCatalog(report, canonicalPath, seenCandidates)

proc walkDirectory(directory: string; report: var ScanReport;
                   seenCandidates: var HashSet[string]) =
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
    of pcDir:
      walkDirectory(entry.path, report, seenCandidates)
    of pcFile, pcLinkToFile:
      if entry.path.endsWith(".clap"):
        inspectCandidate(report, entry.path, seenCandidates)
    else:
      # Nested symlink directories and special filesystem objects are not
      # followed or loaded. A configured root itself was canonicalized above.
      discard

proc scanPlugins*(explicitRoots: openArray[string];
                  clapPath = getEnv("CLAP_PATH")): ScanReport =
  let roots = discoveryRoots(explicitRoots, clapPath = clapPath)
  var seenRoots = initHashSet[string]()
  var seenCandidates = initHashSet[string]()

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
    walkDirectory(canonical, result, seenCandidates)
