# Nimble 0.20 accepts only dotted numeric package versions and requires a
# literal assignment. tests/unit/test_version.nim verifies this value against
# the numeric core of VERSION.
version       = "0.0.10"
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

proc verifyNoEagerPlatformDependency(path: string) =
  exec "command -v readelf >/dev/null 2>&1 || { " &
       "echo 'readelf is required for ELF dependency verification' >&2; " &
       "exit 1; }; dependencies=$(readelf -d " & path & ") || { " &
       "echo 'could not inspect ELF dependencies: " & path & "' >&2; " &
       "exit 1; }; if printf '%s\n' \"$dependencies\" | " &
       "grep -Eq 'libjack.so.0|libdbus-1.so.3|libX11.so.6'; then " &
       "echo 'unexpected eager platform dependency: " & path & "' >&2; " &
       "exit 1; fi"

proc checkReleaseCandidateVersion() =
  let version = readFile("VERSION").strip()
  if version != "0.1.0-rc.1":
    echo "release candidate version is not selected: " & version
    quit(1)
  let packageVersion = version.split('-', maxsplit = 1)[0]
  let nimbleText = readFile("pluginhost.nimble")
  if not nimbleText.contains("version       = \"" & packageVersion & "\""):
    echo "Nimble package version does not match release candidate: " &
      packageVersion
    quit(1)

proc compileReleaseCandidateArtifact() =
  exec "mkdir -p build/release build/nimcache/release"
  exec "nim c --hints:off -d:release --path:src " &
       dependencyPathsClause() &
       " --nimcache:build/nimcache/release " &
       "--out:build/release/pluginhost src/pluginhost.nim"
  verifyNoEagerPlatformDependency("build/release/pluginhost")
  exec "first_line=$(build/release/pluginhost --version | " &
       "{ IFS= read -r line; printf '%s' \"$line\"; }); " &
       "test \"$first_line\" = 'pluginhost 0.1.0-rc.1'"
  exec "python3 -c 'import subprocess,sys; " &
       "text=subprocess.check_output([\"file\", \"build/release/pluginhost\"], " &
       "text=True); " &
       "sys.exit(0 if \"ELF 64-bit\" in text and \"x86-64\" in text else 1)'"
  exec "sha256sum build/release/pluginhost > build/release/pluginhost.sha256"
  exec "test -s build/release/pluginhost.sha256"

proc compileTestBinary() =
  exec "mkdir -p build/test build/nimcache/test-app"
  exec "nim c --hints:off --path:src " & dependencyPathsClause() &
       " --nimcache:build/nimcache/test-app " &
       "--out:build/test/pluginhost src/pluginhost.nim"
  verifyNoEagerPlatformDependency("build/test/pluginhost")

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
  exec "mkdir -p build/integration build/nimcache/integration build/test " &
       "build/fixtures/clap"
  exec "cc -std=gnu11 -fPIC -fno-builtin -Wall -Wextra -Werror " &
       "-pthread $(pkg-config --cflags jack) -c " &
       "tests/rt/live_callback_instrumentation.c " &
       "-o build/integration/live_callback_instrumentation.o"
  exec "cc -std=gnu11 -fno-builtin -Wall -Wextra -Werror -pthread " &
       "$(pkg-config --cflags jack) tests/integration/jack_peer.c " &
       "$(pkg-config --libs jack) -ldl -Wl,-z,defs " &
       "-o build/integration/jack_peer"
  exec "cc -std=gnu11 -fno-builtin -Wall -Wextra -Werror -pthread " &
       "$(pkg-config --cflags jack) tests/integration/jack_midi_peer.c " &
       "$(pkg-config --libs jack) -ldl -Wl,-z,defs " &
       "-o build/integration/jack_midi_peer"
  exec "cc -std=gnu11 -fno-builtin -Wall -Wextra -Werror -pthread " &
       "$(pkg-config --cflags jack) tests/integration/release_peer.c " &
       "$(pkg-config --libs jack) -ldl -Wl,-z,defs " &
       "-o build/integration/release_peer"
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -Wl,-z,defs -Ivendor/clap/include " &
       "-DPLUGINHOST_EVENT_FIXTURE_MODE=0 " &
       "tests/fixtures/clap/event_fixture.c " &
       "-o build/fixtures/clap/events_raw.clap"
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -Wl,-z,defs -Ivendor/clap/include " &
       "-DPLUGINHOST_AUDIO_FIXTURE_MODE=0 " &
       "tests/fixtures/clap/audio_fixture.c " &
       "-o build/fixtures/clap/audio_tone.clap"
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -Wl,-z,defs -Ivendor/clap/include " &
       "-DPLUGINHOST_AUDIO_FIXTURE_MODE=13 " &
       "tests/fixtures/clap/audio_fixture.c " &
       "-o build/fixtures/clap/audio_state.clap"

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

proc checkRequiredReleasePath(name: string) =
  let path = getEnv(name)
  if path.len == 0:
    echo "release acceptance prerequisite missing: set " & name &
      " to an absolute plugin path"
    quit(1)
  if path[0] != '/':
    echo "release acceptance prerequisite must be absolute: " & name
    quit(1)
  if not fileExists(path):
    echo "release acceptance prerequisite does not exist: " & path
    quit(1)

proc checkReleaseAcceptancePrerequisites() =
  for name in [
      "PLUGINHOST_RELEASE_INSTRUMENT_PLUGIN",
      "PLUGINHOST_RELEASE_SECOND_INSTRUMENT_PLUGIN",
      "PLUGINHOST_RELEASE_EFFECT_PLUGIN",
      "PLUGINHOST_RELEASE_COMPATIBILITY_PLUGIN",
    ]:
    checkRequiredReleasePath(name)
  for name in [
      "PLUGINHOST_RELEASE_INSTRUMENT_ID",
      "PLUGINHOST_RELEASE_SECOND_INSTRUMENT_ID",
      "PLUGINHOST_RELEASE_EFFECT_ID",
      "PLUGINHOST_RELEASE_COMPATIBILITY_ID",
    ]:
    if getEnv(name).len == 0:
      echo "release acceptance prerequisite missing: set " & name
      quit(1)

proc checkIntegrationPrerequisites() =
  verifyIntegrationPrerequisiteFailure()
  exec "python3 tests/integration/run_pipewire_jack.py --check-only"

proc compileLiveIntegrationTest(source, output: string) =
  exec "nim c --hints:off --path:src --path:tests " &
       dependencyPathsClause() &
       " --nimcache:build/nimcache/integration/" & output &
       " --passL:build/integration/live_callback_instrumentation.o" &
       rtInstrumentationLinkFlags() &
       " --out:build/test/" & output & " " & source

proc compileControlIntegrationTest(source, output: string) =
  exec "nim c --hints:off --path:src --path:tests " &
       dependencyPathsClause() &
       " --nimcache:build/nimcache/integration/" & output &
       " --out:build/test/" & output & " " & source

proc compileForeignThreadRaceFixture() =
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -pthread -Wl,-z,defs -Ivendor/clap/include " &
       "tests/integration/foreign_thread_race_fixture.c " &
       "-o build/fixtures/clap/foreign_thread_race.clap"

proc compileForeignThreadTeardownTest() =
  exec "nim c --hints:off -d:nimAllocStats --path:src --path:tests " &
       dependencyPathsClause() &
       " --nimcache:build/nimcache/integration/foreign_thread_teardown " &
       " --out:build/test/foreign_thread_teardown " &
       "tests/integration/test_foreign_thread_teardown.nim"
proc runIntegrationTests(checkPrerequisites = true) =
  if checkPrerequisites:
    checkIntegrationPrerequisites()
    checkClapSmokePrerequisite()
  compileLiveIntegrationSupport()
  compileLiveIntegrationTest(
    "tests/integration/test_live_clap_audio.nim", "live_clap_audio")
  compileLiveIntegrationTest(
    "tests/integration/test_live_clap_events.nim", "live_clap_events")
  compileControlIntegrationTest(
    "tests/integration/test_public_run_control.nim", "public_run_control")
  compileLiveIntegrationTest(
    "tests/integration/all_integration_tests.nim", "all_integration_tests")
  exec "PLUGINHOST_TEST_BIN=$PWD/build/test/pluginhost " &
       "PLUGINHOST_CLAP_AUDIO_FIXTURE_DIR=$PWD/build/fixtures/clap " &
       "python3 tests/integration/run_pipewire_jack.py " &
       "--test build/test/public_run_control " &
       "--peer build/integration/jack_peer"
  exec "python3 tests/integration/run_pipewire_jack.py " &
       "--test build/test/live_clap_audio " &
       "--peer build/integration/jack_peer"
  exec "PLUGINHOST_CLAP_EVENT_FIXTURE_DIR=$PWD/build/fixtures/clap " &
       "python3 tests/integration/run_pipewire_jack.py " &
       "--test build/test/live_clap_events " &
       "--peer build/integration/jack_midi_peer"
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

proc compileEventFixtureVariant(name: string; mode: int) =
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -Wl,-z,defs -Ivendor/clap/include " &
       "-DPLUGINHOST_EVENT_FIXTURE_MODE=" & $mode & " " &
       "tests/fixtures/clap/event_fixture.c " &
       "-o build/fixtures/clap/" & name & ".clap"

proc compileGuiFixture() =
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -Wl,-z,defs -Ivendor/clap/include " &
       "tests/fixtures/clap/gui_fixture.c " &
       "-o build/fixtures/clap/gui.clap"

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
  compileClapFixtureVariant("parameter_out_of_range", 25)
  compileClapFixtureVariant("parameter_get_value_fail", 26)
  compileClapFixtureVariant("parameter_value_nan", 27)
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
  compilePortFixtureVariant("audio_dangling_zero_pair", 30)
  compileAudioFixtureVariant("audio_tone", 0)
  compileAudioFixtureVariant("audio_gain", 1)
  compileAudioFixtureVariant("audio_multi", 2)
  compileAudioFixtureVariant("audio_activate_fail", 3)
  compileAudioFixtureVariant("audio_start_fail", 4)
  compileAudioFixtureVariant("audio_process_error", 5)
  compileAudioFixtureVariant("audio_process_sleep", 6)
  compileAudioFixtureVariant("audio_process_tail", 7)
  compileAudioFixtureVariant("audio_process_continue_if_not_quiet", 8)
  compileAudioFixtureVariant("audio_latency_missing_get", 9)
  compileAudioFixtureVariant("audio_params", 10)
  compileAudioFixtureVariant("audio_port_rescan", 11)
  compileAudioFixtureVariant("audio_tone_sleep", 12)
  compileAudioFixtureVariant("audio_state", 13)
  compileAudioFixtureVariant("audio_state_reject_save", 14)
  compileEventFixtureVariant("events_raw", 0)
  compileEventFixtureVariant("events_clap", 1)
  compileEventFixtureVariant("events_midi2_only", 2)
  compileEventFixtureVariant("events_malformed_output", 3)
  compileEventFixtureVariant("events_note_end", 4)
  compileGuiFixture()
  exec "cc -std=gnu11 -fPIC -shared -fvisibility=hidden " &
       "-Wall -Wextra -Werror -Wl,-z,defs " &
       "tests/fixtures/clap/no_entry_fixture.c " &
       "-o build/fixtures/clap/no_entry.clap"
proc runReleaseAcceptanceTests(checkPrerequisites = true) =
  if checkPrerequisites:
    checkIntegrationPrerequisites()
    checkReleaseAcceptancePrerequisites()
  compileTestBinary()
  compileClapFixtures()
  compileForeignThreadRaceFixture()
  compileLiveIntegrationSupport()
  compileLiveIntegrationTest(
    "tests/integration/test_host_overhead.nim", "host_overhead")
  compileControlIntegrationTest(
    "tests/integration/test_release_acceptance.nim", "release_acceptance")
  compileControlIntegrationTest(
    "tests/integration/test_jack_loss.nim", "jack_loss")
  compileForeignThreadTeardownTest()
  exec "PLUGINHOST_TEST_BIN=$PWD/build/test/pluginhost " &
       "PLUGINHOST_CLAP_FIXTURE_DIR=$PWD/build/fixtures/clap " &
       "PLUGINHOST_RELEASE_PEER=$PWD/build/integration/release_peer " &
       "python3 tests/integration/run_pipewire_jack.py " &
       "--test build/test/release_acceptance " &
       "--peer build/integration/release_peer"
  exec "PLUGINHOST_TEST_BIN=$PWD/build/test/pluginhost " &
       "PLUGINHOST_CLAP_FIXTURE_DIR=$PWD/build/fixtures/clap " &
       "python3 tests/integration/run_pipewire_jack.py " &
       "--test build/test/foreign_thread_teardown " &
       "--peer build/integration/jack_peer"
  exec "python3 tests/integration/run_pipewire_jack.py " &
       "--test build/test/host_overhead " &
       "--peer build/integration/jack_peer"
  exec "PLUGINHOST_TEST_BIN=$PWD/build/test/pluginhost " &
       "PLUGINHOST_CLAP_FIXTURE_DIR=$PWD/build/fixtures/clap " &
       "python3 tests/integration/run_pipewire_jack.py " &
       "--test build/test/jack_loss " &
       "--peer build/integration/jack_peer"

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
       "$(pkg-config --cflags jack x11 dbus-1) -c c/abi_probe.c " &
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
  verifyNoEagerPlatformDependency("build/test/all_abi_tests")

proc runGeneratedCallbackAudit(probeCache = "build/nimcache/rt-alloc") =
  exec "rm -rf build/nimcache/rt-product && " &
       "mkdir -p build/nimcache/rt-product"
  exec "nim c --compileOnly --hints:off --path:src --path:tests " &
       dependencyPathsClause() & " --nimcache:build/nimcache/rt-product " &
       "tests/rt/generated_audit_target.nim"
  exec "python3 tests/rt/audit_generated_callback.py " &
       "build/nimcache/rt-product"
  exec "python3 tests/rt/audit_generated_callback.py --probes " &
       probeCache
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
  exec "mkdir -p build/fixtures/clap"
  compileEventFixtureVariant("events_raw", 0)
  compileEventFixtureVariant("events_note_end", 4)
  exec "PLUGINHOST_FFI_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_ffi_fixture.so " &
       "PLUGINHOST_JACK_FAKE_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_jack_fake_fixture.so " &
       "PLUGINHOST_CLAP_EVENT_FIXTURE_DIR=$PWD/build/fixtures/clap " &
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
       "PLUGINHOST_CLAP_EVENT_FIXTURE_DIR=$PWD/build/fixtures/clap " &
       "nim c -r --hints:off --path:src --path:tests " &
       dependencyPathsClause() & " --nimcache:build/nimcache/fixtures " &
       "--out:build/test/all_fixture_tests tests/fixtures/all_fixture_tests.nim"
proc compileHardeningTests() =
  compileFfiFixture()
  compilePartialJackFixture()
  compileFakeJackFixture()
  compileClapFixtures()
  exec "mkdir -p build/nimcache/hardening build/test"
  exec "nim c --hints:off --path:src --path:tests " &
       dependencyPathsClause() & " --nimcache:build/nimcache/hardening " &
       "--out:build/test/all_hardening_tests " &
       "tests/hardening/all_hardening_tests.nim"

proc runHardeningTests() =
  exec "PLUGINHOST_FFI_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_ffi_fixture.so " &
       "PLUGINHOST_JACK_PARTIAL_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_jack_partial_fixture.so " &
       "PLUGINHOST_JACK_FAKE_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_jack_fake_fixture.so " &
       "PLUGINHOST_CLAP_FIXTURE_DIR=$PWD/build/fixtures/clap " &
       "build/test/all_hardening_tests"

proc compileSanitizedRt() =
  exec "rm -rf build/nimcache/sanitize-rt && " &
       "mkdir -p build/nimcache/sanitize-rt build/test"
  exec "nim c --cc:clang --hints:off -d:nimAllocStats " &
       "--passC:-fsanitize=address,undefined " &
       "--passL:-fsanitize=address,undefined --path:src --path:tests " &
       dependencyPathsClause() & " --nimcache:build/nimcache/sanitize-rt " &
       "--out:build/test/sanitize_rt tests/rt/all_rt_tests.nim"

proc runSanitizedChecks() =
  exec "PLUGINHOST_FFI_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_ffi_fixture.so " &
       "PLUGINHOST_JACK_PARTIAL_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_jack_partial_fixture.so " &
       "PLUGINHOST_JACK_FAKE_FIXTURE=$PWD/build/fixtures/" &
       "libpluginhost_jack_fake_fixture.so " &
       "PLUGINHOST_CLAP_EVENT_FIXTURE_DIR=$PWD/build/fixtures/clap " &
       "PLUGINHOST_CLAP_FIXTURE_DIR=$PWD/build/fixtures/clap " &
       "python3 tests/rt/run_sanitizers.py " &
       "--asan build/test/sanitize_rt " &
       "--valgrind build/test/all_hardening_tests"

proc runSanitizeTask() =
  exec "command -v clang >/dev/null 2>&1 || { " &
       "echo 'clang is required for sanitizer checks' >&2; exit 1; }"
  exec "command -v valgrind >/dev/null 2>&1 || { " &
       "echo 'valgrind is required for ownership checks' >&2; exit 1; }"
  compileSanitizedRt()
  compileHardeningTests()
  compileEventFixtureVariant("events_raw", 0)
  compileEventFixtureVariant("events_note_end", 4)
  runGeneratedCallbackAudit("build/nimcache/sanitize-rt")
  runSanitizedChecks()


proc runGuiTests() =
  exec "mkdir -p build/test build/integration build/nimcache/integration build/fixtures/clap"
  compileGuiFixture()
  exec "cc -std=gnu11 -Wall -Wextra -Werror $(pkg-config --cflags x11) " &
       "tests/integration/x11_send_wm_delete.c $(pkg-config --libs x11) " &
       "-o build/integration/x11_send_wm_delete"
  exec "cc -std=gnu11 -Wall -Wextra -Werror $(pkg-config --cflags dbus-1) " &
       "tests/integration/dbus_fake_watcher.c $(pkg-config --libs dbus-1) " &
       "-o build/integration/dbus_fake_watcher"
  exec "command -v Xvfb >/dev/null 2>&1 || { echo 'Xvfb is required for GUI tests' >&2; exit 1; }"
  exec "command -v xvfb-run >/dev/null 2>&1 || { echo 'xvfb-run is required for GUI tests' >&2; exit 1; }"
  exec "command -v dbus-run-session >/dev/null 2>&1 || { echo 'dbus-run-session is required for GUI tests' >&2; exit 1; }"
  exec "command -v gdbus >/dev/null 2>&1 || { echo 'gdbus is required for GUI tests' >&2; exit 1; }"
  compileControlIntegrationTest(
    "tests/integration/test_x11_window_host.nim", "x11_window_host")
  compileControlIntegrationTest(
    "tests/integration/test_dbus_tray_icon.nim", "dbus_tray_icon")
  exec "command -v readelf >/dev/null 2>&1 || { echo 'readelf is required for GUI tests' >&2; exit 1; }"
  exec "dependencies=$(readelf -d build/test/x11_window_host) || exit 1; " &
       "if printf '%s\\n' \"$dependencies\" | grep -Fq 'libX11.so'; then " &
       "echo 'unexpected eager libX11 dependency in X11 test host' >&2; exit 1; fi"
  exec "dependencies=$(readelf -d build/test/dbus_tray_icon) || exit 1; " &
       "if printf '%s\\n' \"$dependencies\" | grep -Fq 'libdbus-1.so'; then " &
       "echo 'unexpected eager libdbus-1 dependency in D-Bus tray test host' >&2; exit 1; fi"
  exec "PLUGINHOST_X11_SEND_DELETE=$PWD/build/integration/x11_send_wm_delete " &
       "PLUGINHOST_CLAP_FIXTURE_DIR=$PWD/build/fixtures/clap " &
       "xvfb-run -a -s '-screen 0 1024x768x24 -extension GLX -nolisten tcp' " &
       "build/test/x11_window_host"
  exec "PLUGINHOST_DBUS_FAKE_WATCHER=$PWD/build/integration/dbus_fake_watcher " &
       "dbus-run-session -- xvfb-run -a " &
       "-s '-screen 0 1024x768x24 -extension GLX -nolisten tcp' " &
       "build/test/dbus_tray_icon"
  exec "PLUGINHOST_DBUS_FAKE_WATCHER=$PWD/build/integration/dbus_fake_watcher " &
       "PLUGINHOST_DBUS_WATCHER_VARIANT=kde dbus-run-session -- xvfb-run -a " &
       "-s '-screen 0 1024x768x24 -extension GLX -nolisten tcp' " &
       "build/test/dbus_tray_icon"

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
  compileTestBinary()
  runIntegrationTests()

task testAcceptance, "Run the public release acceptance matrix":
  runReleaseAcceptanceTests()

task testGui, "Run the X11 GUI and D-Bus tray tests under Xvfb":
  runGuiTests()

task testHardening, "Run hostile-input and resource-ownership checks":
  compileHardeningTests()
  runHardeningTests()

task sanitize, "Run generated-C sanitizers and ownership checks":
  runSanitizeTask()

task all, "Run compile checks, build the executable, and run tests":
  checkIntegrationPrerequisites()
  checkClapSmokePrerequisite()
  checkReleaseAcceptancePrerequisites()
  exec "mkdir -p build/nimcache/check"
  exec "nim check --hints:off --path:src " & dependencyPathsClause() &
       " --nimcache:build/nimcache/check src/pluginhost.nim"
  compileTestBinary()
  runUnitTests()
  runAbiTests()
  runRtTests()
  runClapFixtureTests()
  compileHardeningTests()
  runHardeningTests()
  runIntegrationTests(false)
  runReleaseAcceptanceTests(false)
  runGuiTests()

task releaseCandidate, "Build and inspect the selected release candidate":
  checkClapSmokePrerequisite()
  checkReleaseAcceptancePrerequisites()
  checkReleaseCandidateVersion()
  compileReleaseCandidateArtifact()
