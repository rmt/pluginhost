import std/os

const JackPartialFixturePathEnvironment* =
  "PLUGINHOST_JACK_PARTIAL_FIXTURE"

proc jackPartialFixturePath*(): string =
  result = getEnv(JackPartialFixturePathEnvironment)
  if result.len == 0:
    raise newException(ValueError,
      JackPartialFixturePathEnvironment &
        " must name the compiled partial JACK fixture")
