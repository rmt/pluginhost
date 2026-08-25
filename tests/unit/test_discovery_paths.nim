import std/[unittest]

import pluginhost/discovery/paths

suite "CLAP discovery root policy":
  test "explicit roots are exclusive and preserve order":
    let roots = discoveryRoots(@["first", "second"], "/home/test", "/ignored:/also-ignored")

    check roots.len == 2
    check roots[0].path == "first"
    check roots[0].kind == drkExplicit
    check roots[1].path == "second"
    check roots[1].kind == drkExplicit

  test "standard roots precede non-empty CLAP_PATH entries":
    let roots = discoveryRoots(@[], "/home/test", "/one::/two:")

    check roots.len == 4
    check roots[0].path == "/home/test/.clap"
    check roots[0].kind == drkHome
    check roots[1].path == "/usr/lib/clap"
    check roots[1].kind == drkSystem
    check roots[2].path == "/one"
    check roots[2].kind == drkEnvironment
    check roots[3].path == "/two"
    check roots[3].kind == drkEnvironment
