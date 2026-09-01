import std/unittest

import pluginhost/app/[host_session, run_config]
import pluginhost/domain/[errors, lifecycle]

suite "session lifecycle":
  test "the expected startup and shutdown path is legal":
    var state = ssNew

    check state.transition(ssStarting).isOk
    check state.transition(ssRunning).isOk
    check state.transition(ssStopping).isOk
    check state.transition(ssStopped).isOk
    check state == ssStopped

  test "illegal and repeated transitions fail without changing state":
    var state = ssNew

    let illegal = state.transition(ssRunning)
    check not illegal.isOk
    check illegal.error.kind == hekInvalidTransition
    check state == ssNew

    check state.transition(ssStarting).isOk
    let repeated = state.transition(ssStarting)
    check not repeated.isOk
    check state == ssStarting

  test "public run startup failure cleans process control idempotently":
    var session = initHostSession()
    var config = defaultRunConfig()
    config.pluginPath = "fixture.clap"

    let runResult = session.run(config)
    check not runResult.isOk
    check runResult.error.kind == hekClapPath
    check session.state == ssFailed

    check session.close().isOk
    check session.state == ssStopped
    check session.close().isOk
    check session.state == ssStopped

  test "a never-started session can be closed":
    var session = initHostSession()

    check session.close().isOk
    check session.state == ssStopped
