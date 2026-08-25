import std/[os, strutils]

type
  DiscoveryRootKind* = enum
    drkExplicit = "explicit"
    drkHome = "home"
    drkSystem = "system"
    drkEnvironment = "CLAP_PATH"

  DiscoveryRoot* = object
    path*: string
    kind*: DiscoveryRootKind

const SystemClapRoot* = "/usr/lib/clap"

proc discoveryRoots*(explicit: openArray[string];
                      homeDirectory = getHomeDir();
                      clapPath = getEnv("CLAP_PATH")): seq[DiscoveryRoot] =
  ## Resolves the ordered roots for one scan without touching the filesystem.
  ## Explicit roots are exclusive; the environment is used only otherwise.
  if explicit.len > 0:
    for path in explicit:
      result.add(DiscoveryRoot(path: path, kind: drkExplicit))
    return

  result.add(DiscoveryRoot(
    path: homeDirectory / ".clap",
    kind: drkHome,
  ))
  result.add(DiscoveryRoot(
    path: SystemClapRoot,
    kind: drkSystem,
  ))
  for path in clapPath.split(':'):
    if path.len > 0:
      result.add(DiscoveryRoot(path: path, kind: drkEnvironment))
