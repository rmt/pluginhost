# One safety profile is shared by product, test, ABI, fixture, and RT builds.
switch("mm", "arc")
switch("threads", "on")
switch("panics", "on")
switch("define", "noSignalHandler")
switch("passC", "-I" & thisDir() & "/c")

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
