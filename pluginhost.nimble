# Nimble 0.20 accepts only dotted numeric package versions and requires a
# literal assignment. tests/unit/test_version.nim verifies this value against
# the numeric core of VERSION.
version       = "0.0.2"
author        = "pluginhost contributors"
description   = "A standalone Linux JACK host for CLAP plugins"
license       = "UNLICENSED"
srcDir        = "src"
bin           = @["pluginhost"]

requires "nim >= 2.2.0", "argparse == 4.0.2"

proc dependencyPathsClause(): string =
  result = getPathsClause()
  if result == "--path:":
    result = ""

proc compileTestBinary() =
  exec "mkdir -p build/test build/nimcache/test-app"
  exec "nim c --hints:off --path:src " & dependencyPathsClause() &
       " --nimcache:build/nimcache/test-app " &
       "--out:build/test/pluginhost src/pluginhost.nim"

proc compileFfiFixture() =
  exec "mkdir -p build/fixtures"
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -pthread -Wl,-z,defs " &
       "-Ivendor/clap/include " &
       "tests/fixtures/ffi/ffi_fixture.c " &
       "-o build/fixtures/libpluginhost_ffi_fixture.so"

proc runUnitTests() =
  exec "mkdir -p build/nimcache/tests"
  exec "PLUGINHOST_TEST_BIN=build/test/pluginhost " &
       "nim c -r --hints:off --path:src --path:tests " & dependencyPathsClause() &
       " --nimcache:build/nimcache/tests --out:build/test/all_tests " &
       "tests/all_tests.nim"

proc runAbiTests() =
  exec "mkdir -p build/abi build/nimcache/abi build/test"
  exec "cc -std=gnu11 -Wall -Wextra -Werror -Ivendor/clap/include " &
       "$(pkg-config --cflags jack) -c c/abi_probe.c " &
       "-o build/abi/abi_probe.o"
  compileFfiFixture()
  exec "PLUGINHOST_FFI_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_ffi_fixture.so " &
       "nim c -r --hints:off --mm:arc --threads:on --path:src --path:tests " &
       dependencyPathsClause() & " --nimcache:build/nimcache/abi " &
       "--passL:build/abi/abi_probe.o --out:build/test/all_abi_tests " &
       "tests/abi/all_abi_tests.nim"

proc runRtTests() =
  exec "mkdir -p build/nimcache/rt build/test"
  compileFfiFixture()
  exec "PLUGINHOST_FFI_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_ffi_fixture.so " &
       "nim c -r --hints:off --mm:arc --threads:on -d:nimAllocStats " &
       "--path:src --path:tests " & dependencyPathsClause() &
       " --nimcache:build/nimcache/rt --out:build/test/all_rt_tests " &
       "tests/rt/all_rt_tests.nim"
  exec "python3 tests/rt/audit_generated_callback.py build/nimcache/rt"

task test, "Build the executable and run the fast unit test suite":
  compileTestBinary()
  runUnitTests()

task testAbi, "Run C-versus-Nim ABI conformance tests":
  runAbiTests()

task testRt, "Run the ARC callback allocation and generated-code checks":
  runRtTests()

task all, "Run compile checks, build the executable, and run tests":
  exec "mkdir -p build/nimcache/check"
  exec "nim check --hints:off --path:src " & dependencyPathsClause() &
       " --nimcache:build/nimcache/check src/pluginhost.nim"
  compileTestBinary()
  runUnitTests()
  runAbiTests()
  runRtTests()
