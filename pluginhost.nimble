# Nimble 0.20 accepts only dotted numeric package versions and requires a
# literal assignment. tests/unit/test_version.nim verifies this value against
# the numeric core of VERSION.
version       = "0.0.6"
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

proc verifyNoEagerJackDependency(path: string) =
  exec "command -v readelf >/dev/null 2>&1 || { " &
       "echo 'readelf is required for ELF dependency verification' >&2; " &
       "exit 1; }; dependencies=$(readelf -d " & path & ") || { " &
       "echo 'could not inspect ELF dependencies: " & path & "' >&2; " &
       "exit 1; }; if printf '%s\n' \"$dependencies\" | " &
       "grep -Fq 'libjack.so.0'; then " &
       "echo 'unexpected eager libjack dependency: " & path & "' >&2; " &
       "exit 1; fi"

proc compileTestBinary() =
  exec "mkdir -p build/test build/nimcache/test-app"
  exec "nim c --hints:off --path:src " & dependencyPathsClause() &
       " --nimcache:build/nimcache/test-app " &
       "--out:build/test/pluginhost src/pluginhost.nim"
  verifyNoEagerJackDependency("build/test/pluginhost")

proc compileFfiFixture() =
  exec "mkdir -p build/fixtures"
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -pthread -Wl,-z,defs " &
       "-Ivendor/clap/include " &
       "tests/fixtures/ffi/ffi_fixture.c " &
       "-o build/fixtures/libpluginhost_ffi_fixture.so"

proc compilePartialJackFixture() =
  exec "mkdir -p build/fixtures"
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -Wl,-z,defs " &
       "tests/fixtures/jack/partial_jack_fixture.c " &
       "-o build/fixtures/libpluginhost_jack_partial_fixture.so"

proc compileFakeJackFixture() =
  exec "mkdir -p build/fixtures"
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -pthread -Wl,-z,defs " &
       "$(pkg-config --cflags jack) " &
       "tests/fixtures/jack/fake_jack_fixture.c " &
       "-o build/fixtures/libpluginhost_jack_fake_fixture.so"

proc rtInstrumentationLinkFlags(): string =
  const wrappedSymbols = [
    "pluginhost_jack_process_callback",
    "pluginhost_jack_shutdown_callback",
    "pluginhost_jack_info_shutdown_callback",
    "pluginhost_jack_buffer_size_callback",
    "pluginhost_jack_sample_rate_callback",
    "pluginhost_jack_xrun_callback",
    "pluginhost_jack_freewheel_callback",
    "pluginhost_jack_latency_callback",
    "malloc", "calloc", "realloc", "free", "aligned_alloc",
    "posix_memalign", "mmap", "munmap",
    "pthread_mutex_lock", "pthread_mutex_trylock",
    "pthread_mutex_timedlock", "pthread_rwlock_rdlock",
    "pthread_rwlock_wrlock", "pthread_rwlock_tryrdlock",
    "pthread_rwlock_trywrlock", "pthread_spin_lock",
    "pthread_spin_trylock", "pthread_cond_wait",
    "pthread_cond_timedwait",
    "printf", "vprintf", "fprintf", "vfprintf", "sprintf",
    "vsprintf", "snprintf", "vsnprintf", "puts", "fputs",
    "fwrite", "putchar",
    "open", "open64", "openat", "openat64", "read", "pread",
    "write", "pwrite", "writev", "close", "fsync", "fdatasync",
  ]
  for symbol in wrappedSymbols:
    result.add(" --passL:-Wl,--wrap=" & symbol)

proc compileLiveIntegrationSupport() =
  exec "mkdir -p build/integration build/nimcache/integration build/test"
  exec "cc -std=gnu11 -fPIC -fno-builtin -Wall -Wextra -Werror " &
       "-pthread $(pkg-config --cflags jack) -c " &
       "tests/rt/live_callback_instrumentation.c " &
       "-o build/integration/live_callback_instrumentation.o"
  exec "cc -std=gnu11 -fno-builtin -Wall -Wextra -Werror -pthread " &
       "$(pkg-config --cflags jack) tests/integration/jack_peer.c " &
       "$(pkg-config --libs jack) -ldl -Wl,-z,defs " &
       "-o build/integration/jack_peer"

proc verifyIntegrationPrerequisiteFailure() =
  exec "python=$(command -v python3); set +e; " &
       "output=$(env PATH=/pluginhost-missing-prerequisites \"$python\" " &
       "tests/integration/run_pipewire_jack.py --check-only 2>&1); " &
       "status=$?; set -e; " &
       "if [ \"$status\" -ne 1 ] || ! printf '%s\\n' \"$output\" | " &
       "grep -Fq 'integration test did not run'; then " &
       "printf '%s\\n' \"$output\" >&2; " &
       "echo 'missing integration prerequisites produced a false pass' >&2; " &
       "exit 1; fi; " &
       "echo 'Missing integration prerequisites fail as required'"

proc checkClapSmokePrerequisite() =
  let path = getEnv("PLUGINHOST_CLAP_SMOKE_PLUGIN")
  if path.len == 0:
    echo "CLAP smoke prerequisite missing: set PLUGINHOST_CLAP_SMOKE_PLUGIN to an absolute headless plugin path"
    quit(1)
  if path[0] != '/':
    echo "CLAP smoke prerequisite must be an absolute path: " & path
    quit(1)
  if not fileExists(path):
    echo "CLAP smoke prerequisite does not exist: " & path
    quit(1)

proc checkIntegrationPrerequisites() =
  verifyIntegrationPrerequisiteFailure()
  exec "python3 tests/integration/run_pipewire_jack.py --check-only"

proc runIntegrationTests(checkPrerequisites = true) =
  if checkPrerequisites:
    checkIntegrationPrerequisites()
    checkClapSmokePrerequisite()
  compileLiveIntegrationSupport()
  exec "nim c --hints:off --path:src --path:tests " &
       dependencyPathsClause() &
       " --nimcache:build/nimcache/integration " &
       "--passL:build/integration/live_callback_instrumentation.o" &
       rtInstrumentationLinkFlags() &
       " --out:build/test/all_integration_tests " &
       "tests/integration/all_integration_tests.nim"
  exec "python3 tests/integration/run_pipewire_jack.py " &
       "--test build/test/all_integration_tests " &
       "--peer build/integration/jack_peer"

proc compileClapFixtureVariant(name: string; mode: int) =
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -pthread -Wl,-z,defs -Ivendor/clap/include " &
       "-DPLUGINHOST_CLAP_FIXTURE_MODE=" & $mode & " " &
       "tests/fixtures/clap/clap_fixture.c " &
       "-o build/fixtures/clap/" & name & ".clap"

proc compilePortFixtureVariant(name: string; mode: int) =
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -Wl,-z,defs -Ivendor/clap/include " &
       "-DPLUGINHOST_PORT_FIXTURE_MODE=" & $mode & " " &
       "tests/fixtures/clap/port_fixture.c " &
       "-o build/fixtures/clap/" & name & ".clap"

proc compileAudioFixtureVariant(name: string; mode: int) =
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -Wl,-z,defs -Ivendor/clap/include " &
       "-DPLUGINHOST_AUDIO_FIXTURE_MODE=" & $mode & " " &
       "tests/fixtures/clap/audio_fixture.c " &
       "-o build/fixtures/clap/" & name & ".clap"

proc compileClapFixtures() =
  exec "mkdir -p build/fixtures/clap"
  compileClapFixtureVariant("valid", 0)
  compileClapFixtureVariant("incompatible_entry", 1)
  compileClapFixtureVariant("init_fail", 2)
  compileClapFixtureVariant("missing_factory", 3)
  compileClapFixtureVariant("null_descriptor", 4)
  compileClapFixtureVariant("blank_id", 5)
  compileClapFixtureVariant("blank_name", 6)
  compileClapFixtureVariant("invalid_utf8", 7)
  compileClapFixtureVariant("duplicate_id", 8)
  compileClapFixtureVariant("too_many_descriptors", 9)
  compileClapFixtureVariant("oversized_text", 10)
  compileClapFixtureVariant("too_many_features", 11)
  compileClapFixtureVariant("missing_factory_callback", 12)
  compileClapFixtureVariant("missing_entry_callback", 13)
  compileClapFixtureVariant("exact_limits", 14)
  compileClapFixtureVariant("too_much_metadata", 15)
  compileClapFixtureVariant("incompatible_descriptor", 16)
  compileClapFixtureVariant("null_id", 17)
  compileClapFixtureVariant("zero_descriptors", 18)
  compileClapFixtureVariant("create_guard", 19)
  compileClapFixtureVariant("plugin_init_fail", 20)
  compileClapFixtureVariant("create_fail", 21)
  compileClapFixtureVariant("missing_plugin_destroy", 22)
  compileClapFixtureVariant("plugin_wrong_id", 23)
  compileClapFixtureVariant("plugin_incompatible_descriptor", 24)
  compilePortFixtureVariant("ports_valid", 0)
  compilePortFixtureVariant("ports_none", 1)
  compilePortFixtureVariant("audio_missing_count", 2)
  compilePortFixtureVariant("audio_missing_get", 3)
  compilePortFixtureVariant("audio_too_many", 4)
  compilePortFixtureVariant("audio_get_fail", 5)
  compilePortFixtureVariant("audio_invalid_id", 6)
  compilePortFixtureVariant("audio_duplicate_id", 7)
  compilePortFixtureVariant("audio_zero_channels", 8)
  compilePortFixtureVariant("audio_unterminated_name", 9)
  compilePortFixtureVariant("audio_oversized_type", 10)
  compilePortFixtureVariant("audio_inconsistent", 11)
  compilePortFixtureVariant("audio_bad_pair", 12)
  compilePortFixtureVariant("audio_too_many_channels", 13)
  compilePortFixtureVariant("note_missing_count", 14)
  compilePortFixtureVariant("note_missing_get", 15)
  compilePortFixtureVariant("note_too_many", 16)
  compilePortFixtureVariant("note_get_fail", 17)
  compilePortFixtureVariant("note_invalid_id", 18)
  compilePortFixtureVariant("note_duplicate_id", 19)
  compilePortFixtureVariant("note_unterminated_name", 20)
  compilePortFixtureVariant("note_bad_supported", 21)
  compilePortFixtureVariant("note_bad_preferred", 22)
  compilePortFixtureVariant("render_missing_set", 23)
  compilePortFixtureVariant("render_reject", 24)
  compilePortFixtureVariant("render_hard", 25)
  compilePortFixtureVariant("audio_bad_type", 26)
  compilePortFixtureVariant("audio_bad_preference", 27)
  compilePortFixtureVariant("render_missing_requirement", 28)
  compilePortFixtureVariant("ports_exact_limits", 29)
  compileAudioFixtureVariant("audio_tone", 0)
  compileAudioFixtureVariant("audio_gain", 1)
  compileAudioFixtureVariant("audio_multi", 2)
  compileAudioFixtureVariant("audio_activate_fail", 3)
  compileAudioFixtureVariant("audio_start_fail", 4)
  compileAudioFixtureVariant("audio_process_error", 5)
  compileAudioFixtureVariant("audio_process_sleep", 6)
  compileAudioFixtureVariant("audio_process_tail", 7)
  compileAudioFixtureVariant("audio_process_continue_if_not_quiet", 8)
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -Wl,-z,defs " &
       "tests/fixtures/clap/no_entry_fixture.c " &
       "-o build/fixtures/clap/no_entry.clap"

proc runUnitTests() =
  compileFakeJackFixture()
  exec "mkdir -p build/nimcache/tests"
  exec "PLUGINHOST_TEST_BIN=build/test/pluginhost " &
       "PLUGINHOST_JACK_FAKE_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_jack_fake_fixture.so " &
       "nim c -r --hints:off --path:src --path:tests " & dependencyPathsClause() &
       " --nimcache:build/nimcache/tests --out:build/test/all_tests " &
       "tests/all_tests.nim"

proc runAbiTests() =
  exec "mkdir -p build/abi build/nimcache/abi build/test"
  exec "cc -std=gnu11 -Wall -Wextra -Werror -Ic -Ivendor/clap/include " &
       "$(pkg-config --cflags jack) -c c/abi_probe.c " &
       "-o build/abi/abi_probe.o"
  compileFfiFixture()
  compilePartialJackFixture()
  exec "PLUGINHOST_FFI_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_ffi_fixture.so " &
       "PLUGINHOST_JACK_PARTIAL_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_jack_partial_fixture.so " &
       "nim c -r --hints:off --path:src --path:tests " &
       dependencyPathsClause() & " --nimcache:build/nimcache/abi " &
       "--passL:build/abi/abi_probe.o --out:build/test/all_abi_tests " &
       "tests/abi/all_abi_tests.nim"
  verifyNoEagerJackDependency("build/test/all_abi_tests")

proc runGeneratedCallbackAudit() =
  exec "rm -rf build/nimcache/rt-product && " &
       "mkdir -p build/nimcache/rt-product"
  exec "nim c --compileOnly --hints:off --path:src --path:tests " &
       dependencyPathsClause() & " --nimcache:build/nimcache/rt-product " &
       "tests/rt/generated_audit_target.nim"
  exec "python3 tests/rt/audit_generated_callback.py " &
       "build/nimcache/rt-product"
  exec "python3 tests/rt/audit_generated_callback.py --probes " &
       "build/nimcache/rt-alloc"
  exec "rm -rf build/nimcache/rt-canary && mkdir -p build/nimcache/rt-canary"
  exec "nim c --compileOnly --hints:off --path:src --path:tests " &
       dependencyPathsClause() & " --nimcache:build/nimcache/rt-canary " &
       "tests/rt/negative_callback_canary.nim"
  exec "set +e; output=$(python3 tests/rt/audit_generated_callback.py " &
       "--canary build/nimcache/rt-canary " &
       "pluginhost_rt_audit_negative_canary 2>&1); status=$?; set -e; " &
       "printf '%s\\n' \"$output\"; " &
       "if [ \"$status\" -ne 1 ] || ! printf '%s\\n' \"$output\" | " &
       "grep -Fq 'C allocation or deallocation'; then " &
       "echo 'negative generated callback canary was not rejected as required' >&2; " &
       "exit 1; fi; " &
       "echo 'Negative generated callback canary rejected as required'"

proc runRtTests() =
  exec "mkdir -p build/nimcache/rt-alloc build/test"
  compileFfiFixture()
  compileFakeJackFixture()
  exec "PLUGINHOST_FFI_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_ffi_fixture.so " &
       "PLUGINHOST_JACK_FAKE_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_jack_fake_fixture.so " &
       "nim c -r --hints:off -d:nimAllocStats " &
       "--path:src --path:tests " & dependencyPathsClause() &
       " --nimcache:build/nimcache/rt-alloc --out:build/test/all_rt_tests " &
       "tests/rt/all_rt_tests.nim"
  runGeneratedCallbackAudit()

proc runClapFixtureTests() =
  compileClapFixtures()
  compileFakeJackFixture()
  exec "mkdir -p build/nimcache/fixtures build/test"
  exec "PLUGINHOST_TEST_BIN=$PWD/build/test/pluginhost " &
       "PLUGINHOST_JACK_FAKE_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_jack_fake_fixture.so " &
       "PLUGINHOST_CLAP_FIXTURE_DIR=$PWD/build/fixtures/clap " &
       "PLUGINHOST_CLAP_AUDIO_FIXTURE_DIR=$PWD/build/fixtures/clap " &
       "nim c -r --hints:off --path:src --path:tests " &
       dependencyPathsClause() & " --nimcache:build/nimcache/fixtures " &
       "--out:build/test/all_fixture_tests tests/fixtures/all_fixture_tests.nim"

task test, "Build the executable and run the fast unit test suite":
  compileTestBinary()
  runUnitTests()

task testAbi, "Run C-versus-Nim ABI conformance tests":
  runAbiTests()

task testFixtures, "Build and test the synthetic CLAP fixtures":
  compileTestBinary()
  runClapFixtureTests()

task testRt, "Run callback allocation and generated-code safety checks":
  runRtTests()

task testIntegration, "Run isolated live PipeWire-JACK integration tests":
  runIntegrationTests()

task all, "Run compile checks, build the executable, and run tests":
  checkIntegrationPrerequisites()
  checkClapSmokePrerequisite()
  exec "mkdir -p build/nimcache/check"
  exec "nim check --hints:off --path:src " & dependencyPathsClause() &
       " --nimcache:build/nimcache/check src/pluginhost.nim"
  compileTestBinary()
  runUnitTests()
  runAbiTests()
  runRtTests()
  runClapFixtureTests()
  runIntegrationTests(false)
