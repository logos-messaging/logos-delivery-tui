## logos-delivery-tui entry point: parse the CLI, wire the control layer, then
## run either the TUI or the headless runner on the same chronos loop.

{.push raises: [].}

import std/os
import chronos, chronicles, results
import app/[cli, node_host, settings]
import control/[tui_brokers, log_ctl, stats_ctl, messaging_ctl, health_ctl, config_ctl,
  scenario_ctl]
import headless/runner
import view/shell

proc initControl(c: CliConf): Result[void, string] =
  log_ctl.init(c.logLevel)
  if c.logFile.len > 0:
    ?openLogFile(c.logFile)
  host().onAfterCreate(log_ctl.afterNodeCreate)
  host().installProviders()
  stats_ctl.init()
  messaging_ctl.init()
  health_ctl.init()
  config_ctl.init()
  scenario_ctl.init()
  ok()

proc main(): int =
  let c = parseCli(commandLineParams()).valueOr:
    try:
      stderr.writeLine "error: " & error & "\n\n" & Usage
    except IOError:
      discard
    return 2
  if c.help:
    echo Usage
    return 0

  host().confJson =
    if c.nodeConf.len > 0:
      loadText(c.nodeConf).valueOr:
        try:
          stderr.writeLine "error: " & error
        except IOError:
          discard
        return 2
    else:
      DefaultNodeConf

  initControl(c).isOkOr:
    try:
      stderr.writeLine "error: " & error
    except IOError:
      discard
    return 2

  try:
    if c.headless:
      waitFor runHeadless(c)
    else:
      waitFor runTui(c)
  except CatchableError as e:
    try:
      stderr.writeLine "fatal: " & e.msg
    except IOError:
      discard
    1
  finally:
    closeLogFile()

when isMainModule:
  quit main()
