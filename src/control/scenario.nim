## Scenario file model and parser (no node dependency, unit-testable).
##
## {
##   "name": "ping-pong",
##   "nodeConf": "../logos-test.json",   # optional, relative to this file
##   "startNode": true,                  # optional, default true
##   "steps": [ { "action": "waitHealthy", "timeoutS": 60 }, ... ]
## }

{.push raises: [].}

import std/[json, os, strutils, random, times]
import results

type
  Action* {.pure.} = enum
    waitHealthy
    subscribe
    unsubscribe
    send
    sendPeriodic
    sleep
    disconnectPeer
    disconnectAllPeers
    dialPeer
    stopNode
    startNode
    restartNode
    setLogLevel
    expect
    log

  Step* = object
    action*: Action
    params*: JsonNode
    line*: string ## compact JSON of the step, for progress output

  Scenario* = object
    name*: string
    path*: string ## file the scenario was loaded from ("" if inline)
    nodeConf*: string ## resolved path, "" = keep the node's current config
    startNode*: bool
    steps*: seq[Step]

const Metrics* = ["sent", "propagated", "received", "seen", "errors", "peers"]
const Ops* = [">=", ">", "<=", "<", "==", "!="]

proc str*(p: JsonNode, key: string, default = ""): string =
  let n = p.getOrDefault(key)
  if not n.isNil and n.kind == JString:
    n.getStr()
  else:
    default

proc num*(p: JsonNode, key: string, default = 0): int =
  let n = p.getOrDefault(key)
  if not n.isNil and n.kind == JInt:
    n.getInt()
  else:
    default

proc flag*(p: JsonNode, key: string, default = false): bool =
  let n = p.getOrDefault(key)
  if not n.isNil and n.kind == JBool:
    n.getBool()
  else:
    default

proc requireStr(p: JsonNode, key: string, idx: int): Result[void, string] =
  if p.str(key).len == 0:
    return err("step " & $(idx + 1) & ": '" & key & "' (string) is required")
  ok()

proc validate(s: Step, idx: int): Result[void, string] =
  let p = s.params
  case s.action
  of Action.subscribe, Action.unsubscribe:
    ?p.requireStr("contentTopic", idx)
  of Action.send:
    ?p.requireStr("contentTopic", idx)
  of Action.sendPeriodic:
    ?p.requireStr("contentTopic", idx)
    if p.num("intervalMs") <= 0:
      return err("step " & $(idx + 1) & ": 'intervalMs' must be > 0")
  of Action.sleep:
    if p.num("ms") <= 0:
      return err("step " & $(idx + 1) & ": 'ms' must be > 0")
  of Action.disconnectPeer:
    ?p.requireStr("peerId", idx)
  of Action.dialPeer:
    ?p.requireStr("multiaddr", idx)
  of Action.setLogLevel:
    ?p.requireStr("level", idx)
  of Action.expect:
    let m = p.str("metric")
    if m notin Metrics:
      return err("step " & $(idx + 1) & ": 'metric' must be one of " & $Metrics)
    let op = p.str("op", ">=")
    if op notin Ops:
      return err("step " & $(idx + 1) & ": 'op' must be one of " & $Ops)
    let v = p.getOrDefault("value")
    if v.isNil or v.kind != JInt:
      return err("step " & $(idx + 1) & ": 'value' (int) is required")
  of Action.waitHealthy, Action.disconnectAllPeers, Action.stopNode,
      Action.startNode, Action.restartNode, Action.log:
    discard
  ok()

proc parseScenario*(text: string, path = ""): Result[Scenario, string] =
  let root =
    try:
      parseJson(text)
    except CatchableError as e:
      return err("invalid scenario JSON: " & e.msg)
  if root.kind != JObject:
    return err("scenario must be a JSON object")
  var sc = Scenario(
    name: root.str("name", path.extractFilename), path: path,
    startNode: root.flag("startNode", true),
  )
  let nc = root.str("nodeConf")
  if nc.len > 0:
    sc.nodeConf =
      if nc.isAbsolute or path.len == 0: nc
      else: path.parentDir / nc
  let steps = root.getOrDefault("steps")
  if steps.isNil or steps.kind != JArray:
    return err("scenario needs a 'steps' array")
  for i, n in steps.getElems():
    if n.kind != JObject:
      return err("step " & $(i + 1) & " must be an object")
    let a = n.str("action")
    let action =
      try:
        parseEnum[Action](a)
      except ValueError:
        return err("step " & $(i + 1) & ": unknown action '" & a & "'")
    let st = Step(action: action, params: n, line: $n)
    ?st.validate(i)
    sc.steps.add st
  ok(sc)

proc loadScenario*(path: string): Result[Scenario, string] =
  let text =
    try:
      readFile(path)
    except CatchableError as e:
      return err("cannot read scenario " & path & ": " & e.msg)
  parseScenario(text, path)

proc expand*(tmpl: string, seq: int, peerId: string): string =
  ## Payload placeholders: {seq} {peerId} {ts} {rand:N}
  result = tmpl.multiReplace(("{seq}", $seq), ("{peerId}", peerId))
  if "{ts}" in result:
    let ts =
      try:
        now().format("yyyy-MM-dd'T'HH:mm:ss'.'fff")
      except CatchableError:
        ""
    result = result.replace("{ts}", ts)
  while true:
    let i = result.find("{rand:")
    if i < 0:
      break
    let j = result.find('}', i)
    if j < 0:
      break
    let n =
      try:
        parseInt(result[i + 6 ..< j])
      except ValueError:
        8
    var s = newString(max(n, 0))
    for k in 0 ..< s.len:
      s[k] = char(ord('a') + rand(25))
    result = result[0 ..< i] & s & result[j + 1 .. ^1]

proc compare*(lhs: int, op: string, rhs: int): bool =
  case op
  of ">=": lhs >= rhs
  of ">": lhs > rhs
  of "<=": lhs <= rhs
  of "<": lhs < rhs
  of "==": lhs == rhs
  of "!=": lhs != rhs
  else: false

{.pop.}
