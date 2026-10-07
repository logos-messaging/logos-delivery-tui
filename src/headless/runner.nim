## Headless mode: the same controllers without illview. Logs stay on the
## terminal; a scenario (if given) runs to completion and decides the exit
## code. Without a scenario the node runs until Ctrl-C.

{.push raises: [].}

import std/json
import chronos, chronicles, results
import ../app/[cli, node_host]
import ../control/[tui_brokers, scenario_ctl, stats_ctl]

logScope:
  topics = "ldtui headless"

var gStop {.threadvar.}: Future[void]

proc onCtrlC() {.noconv.} =
  {.cast(gcsafe).}:
    if not gStop.isNil and not gStop.finished:
      gStop.complete()

proc writeReport(f: File, e: TuiScenarioProgress) =
  try:
    f.writeLine($(%*{"running": e.running, "step": e.step, "total": e.total, "msg": e.msg}))
    f.flushFile()
  except CatchableError:
    discard

proc runHeadless*(c: CliConf): Future[int] {.async: (raises: []).} =
  gStop = newFuture[void]("ldtui.headless.stop")
  try:
    setControlCHook(onCtrlC)
  except Exception:
    discard

  var report: File
  var hasReport = false
  if c.report.len > 0:
    try:
      report = open(c.report, fmWrite)
      hasReport = true
    except IOError as e:
      error "cannot open report file", path = c.report, error = e.msg
      return 2
    discard TuiScenarioProgress.listen(
      tuiCtx,
      proc(e: TuiScenarioProgress) {.async: (raises: []).} =
        writeReport(report, e),
    )

  var code = 0
  if c.scenario.len > 0:
    let sc = loadScenario(c.scenario).valueOr:
      error "invalid scenario", error = error
      return 2
    let fut = scenario_ctl.run(sc)
    try:
      discard await race(fut, gStop)
    except CatchableError:
      discard
    if not fut.finished:
      await fut.cancelAndWait()
      code = 130
    else:
      let r =
        try:
          fut.read()
        except CatchableError as e:
          Result[void, string].err(e.msg)
      code = if r.isOk: 0 else: 1
  else:
    if not host().isRunning:
      let r = await host().start()
      if r.isErr:
        return 1
    notice "node running headless, Ctrl-C to stop", peerId = host().peerIdStr
    try:
      await gStop
    except CatchableError:
      discard

  discard await host().stop()
  await stats_ctl.shutdown()
  if hasReport:
    try:
      report.close()
    except CatchableError:
      discard
  code

{.pop.}
