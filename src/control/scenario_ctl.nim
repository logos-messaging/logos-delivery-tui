## Scenario runner, shared by headless and TUI mode. Drives the node only
## through the app brokers (same paths the views use), reports through
## `TuiScenarioProgress`.

{.push raises: [].}

import std/[base64, json, os, random]
import chronos, chronicles, results, stew/byteutils
import ../app/node_host
import ./[tui_brokers, scenario, stats_ctl]

export scenario

logScope:
  topics = "ldtui scenario"

type ScenarioCtl = ref object
  runner: Future[Result[void, string]]
  background: seq[Future[void]]
  current: Scenario

var gSc {.threadvar.}: ScenarioCtl

proc progress(running: bool, step, total: int, msg: string) =
  notice "scenario", step, total, msg
  TuiScenarioProgress.emit(
    tuiCtx, TuiScenarioProgress(running: running, step: step, total: total, msg: msg)
  )

proc metric(name: string): int =
  let s = snapshot()
  case name
  of "sent": s.sent
  of "propagated": s.propagated
  of "received": s.received
  of "seen": s.seen
  of "errors": s.errors
  of "peers": s.peers
  else: 0

proc payloadOf(p: JsonNode, seqNo: int): Result[seq[byte], string] =
  let b64 = p.str("payloadBase64")
  if b64.len > 0:
    try:
      return ok(decode(b64).toBytes())
    except ValueError as e:
      return err("invalid payloadBase64: " & e.msg)
  ok(expand(p.str("payload", "ldtui #{seq}"), seqNo, host().peerIdStr).toBytes())

proc sendOne(p: JsonNode, seqNo: int): Future[Result[void, string]] {.async: (raises: []).} =
  let payload = ?payloadOf(p, seqNo)
  discard ?(await TuiSend.request(
    tuiCtx, p.str("contentTopic"), payload, p.flag("ephemeral")
  ))
  ok()

proc sendPeriodic(p: JsonNode) {.async: (raises: []).} =
  let count = p.num("count") # 0 = until the scenario ends
  let interval = p.num("intervalMs")
  let jitter = p.num("jitterMs")
  var n = 1
  while count == 0 or n <= count:
    let r = await sendOne(p, n)
    if r.isErr:
      warn "periodic send failed", seqNo = n, error = r.error
    inc n
    let delay = interval + (if jitter > 0: rand(jitter) else: 0)
    try:
      await sleepAsync(delay.milliseconds)
    except CancelledError:
      return

proc waitHealthy(p: JsonNode): Future[Result[void, string]] {.async: (raises: []).} =
  let timeout = p.num("timeoutS", 60)
  let want = p.str("status", "Connected")
  let deadline = Moment.now() + timeout.seconds
  while Moment.now() < deadline:
    let s = snapshot()
    if host().isRunning and (s.connStatus == want or
        (want == "PartiallyConnected" and s.connStatus == "Connected")):
      return ok()
    try:
      await sleepAsync(500.milliseconds)
    except CancelledError:
      return err("cancelled")
  err("node not " & want & " within " & $timeout & "s (status: " & snapshot().connStatus & ")")

proc expectStep(p: JsonNode): Future[Result[void, string]] {.async: (raises: []).} =
  let m = p.str("metric")
  let op = p.str("op", ">=")
  let want = p.num("value")
  let deadline = Moment.now() + p.num("timeoutS").seconds
  while true:
    let got = metric(m)
    if compare(got, op, want):
      return ok()
    if Moment.now() >= deadline:
      return err("expectation failed: " & m & " " & op & " " & $want & " (got " & $got & ")")
    try:
      await sleepAsync(500.milliseconds)
    except CancelledError:
      return err("cancelled")

proc runStep(c: ScenarioCtl, st: Step): Future[Result[void, string]] {.async: (raises: []).} =
  let p = st.params
  case st.action
  of Action.waitHealthy:
    return await waitHealthy(p)
  of Action.subscribe:
    return await TuiSubscribe.request(tuiCtx, p.str("contentTopic"))
  of Action.unsubscribe:
    return await TuiUnsubscribe.request(tuiCtx, p.str("contentTopic"))
  of Action.send:
    return await sendOne(p, 1)
  of Action.sendPeriodic:
    c.background.add sendPeriodic(p)
    return ok()
  of Action.sleep:
    try:
      await sleepAsync(p.num("ms").milliseconds)
    except CancelledError:
      return err("cancelled")
    return ok()
  of Action.disconnectPeer:
    return await TuiDisconnectPeer.request(tuiCtx, p.str("peerId"))
  of Action.disconnectAllPeers:
    return await TuiDisconnectAll.request(tuiCtx)
  of Action.dialPeer:
    return await TuiDialPeer.request(tuiCtx, p.str("multiaddr"))
  of Action.stopNode:
    return await TuiNodeStop.request(tuiCtx)
  of Action.startNode:
    return await TuiNodeStart.request(tuiCtx, "", false)
  of Action.restartNode:
    var confJson = ""
    let nc = p.str("nodeConf")
    if nc.len > 0:
      let path =
        if nc.isAbsolute or c.current.path.len == 0: nc
        else: c.current.path.parentDir / nc
      try:
        confJson = readFile(path)
      except CatchableError as e:
        return err("cannot read " & path & ": " & e.msg)
    return await TuiNodeRestart.request(tuiCtx, confJson, false)
  of Action.setLogLevel:
    return TuiSetLogLevel.request(tuiCtx, p.str("level"))
  of Action.expect:
    return await expectStep(p)
  of Action.log:
    notice "scenario log", msg = p.str("msg")
    return ok()

proc stopBackground(c: ScenarioCtl) {.async: (raises: []).} =
  for f in c.background:
    if not f.finished:
      await f.cancelAndWait()
  c.background.setLen(0)

proc run*(sc: Scenario): Future[Result[void, string]] {.async: (raises: []).} =
  ## Runs the scenario to completion (or the first failing step).
  let c = gSc
  c.current = sc
  let total = sc.steps.len
  progress(true, 0, total, "starting '" & sc.name & "'")

  if sc.nodeConf.len > 0:
    try:
      host().confJson = readFile(sc.nodeConf)
    except CatchableError as e:
      let msg = "cannot read node config " & sc.nodeConf & ": " & e.msg
      progress(false, 0, total, msg)
      return err(msg)
  if sc.startNode and not host().isRunning:
    let r = await host().start()
    if r.isErr:
      progress(false, 0, total, "node start failed: " & r.error)
      return r

  var res: Result[void, string] = ok()
  for i, st in sc.steps:
    progress(true, i + 1, total, st.line)
    let r =
      try:
        await c.runStep(st)
      except CancelledError:
        Result[void, string].err("cancelled")
    if r.isErr:
      res = err("step " & $(i + 1) & " (" & $st.action & ") failed: " & r.error)
      break
  await c.stopBackground()
  if res.isOk:
    progress(false, total, total, "PASSED '" & sc.name & "'")
  else:
    progress(false, total, total, "FAILED '" & sc.name & "': " & res.error)
  res

proc isRunning*(): bool =
  not gSc.isNil and not gSc.runner.isNil and not gSc.runner.finished

proc init*() =
  randomize()
  let c = ScenarioCtl()
  gSc = c
  discard TuiRunScenario.setProvider(
    tuiCtx,
    proc(path: string): Future[Result[void, string]] {.async.} =
      if isRunning():
        return err("a scenario is already running")
      let sc = ?loadScenario(path)
      c.runner = run(sc)
      ok(),
  )
  discard TuiStopScenario.setProvider(
    tuiCtx,
    proc(): Future[Result[void, string]] {.async.} =
      if not isRunning():
        return err("no scenario running")
      await c.runner.cancelAndWait()
      await c.stopBackground()
      progress(false, 0, c.current.steps.len, "stopped '" & c.current.name & "'")
      ok(),
  )

{.pop.}
