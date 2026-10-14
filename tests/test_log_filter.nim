import std/strutils
import unittest2, results
import ../src/control/log_filter

const
  Relay = "INF 2026-10-13 15:59:49.093+02:00 Relay peer connections                     topics=\"waku node peer_manager\" tid=101496273 file=peer_manager.nim:975 inRelayConns=3"
  Warn = "WRN 2026-10-13 00:23:27.542+02:00 Stopping relay without starting it         topics=\"libp2p relay\" tid=96614435 file=relay.nim:432"
  Err = "ERR 2026-10-13 00:23:27.542+02:00 node failure                               topics=\"ldtui host\" tid=96614435 file=node_host.nim:79 error=\"failed to start: \\\"bind\\\" error\""
  Eq = "NTC 2026-10-13 15:59:49.100+02:00 set a=b in the message                       peerId=16Uiu2HAmXyz"

proc rule(field: LogField, op: LogOp, value: string, join = jAnd, key = ""): Rule =
  Rule(join: join, field: field, op: op, value: value, key: key)

proc filter(rules: varargs[Rule]): LogFilter =
  LogFilter(rules: @rules, enabled: true)

suite "parsing chronicles text records":
  test "level, message, properties (quoted, escaped)":
    let r = parseRecord(Err)
    check:
      r.hasLevel
      r.level == llError
      r.msg == "node failure"
      r.prop("topics") == (true, "ldtui host")
      r.prop("tid") == (true, "96614435")
      r.prop("file") == (true, "node_host.nim:79")
      r.prop("error") == (true, "failed to start: \"bind\" error")

  test "a key=value inside the message stays in the message":
    let r = parseRecord(Eq)
    check:
      r.msg == "set a=b in the message"
      r.props == @[("peerId", "16Uiu2HAmXyz")]

  test "no properties; not a record":
    let r = parseRecord("INF 2026-10-13 15:59:49.093+02:00 just a message")
    check:
      r.msg == "just a message"
      r.props.len == 0
      not parseRecord("  at foo.nim(12) bar").hasLevel
      not parseRecord("inf lowercase is not a level").hasLevel
      not parseRecord("").hasLevel

  test "level names":
    check:
      parseLevel("warn") == (true, llWarn)
      parseLevel("WARNING") == (true, llWarn)
      parseLevel("W") == (true, llWarn)
      parseLevel("err") == (true, llError)
      parseLevel("x")[0] == false

suite "rules and AND / OR":
  test "operators":
    let r = parseRecord(Relay)
    check:
      rule(lfTopics, opContains, "PEER_manager").matches(r)
      not rule(lfTopics, opNotContains, "peer").matches(r)
      rule(lfFile, opEquals, "peer_manager.nim:975").matches(r)
      rule(lfTid, opNotEquals, "1").matches(r)
      rule(lfKey, opEquals, "3", key = "inrelayconns").matches(r)
      rule(lfMsg, opContains, "relay peer").matches(r)
      rule(lfLine, opContains, "tid=101496273").matches(r)
      rule(lfLevel, opAtMost, "info").matches(r)
      not rule(lfLevel, opAtLeast, "WRN").matches(r)
      not rule(lfKey, opContains, "x", key = "missing").matches(r)
      rule(lfKey, opNotContains, "x", key = "missing").matches(r) # absent: not containing

  test "AND binds tighter than OR":
    # level >= WRN AND topics ~ relay  OR  msg ~ connections
    let f = filter(rule(lfLevel, opAtLeast, "WRN"), rule(lfTopics, opContains, "relay"),
                   rule(lfMsg, opContains, "connections", jOr))
    check:
      f.matches(parseRecord(Warn))  # first group
      f.matches(parseRecord(Relay)) # second group
      not f.matches(parseRecord(Err)) # ERR but topics has no relay
      f.describe == "level ≥ WRN AND topics contains relay OR msg contains connections"

  test "disabled or empty filters pass everything":
    var f = filter(rule(lfLevel, opAtLeast, "ERR"))
    check not f.matches(parseRecord(Relay))
    f.enabled = false
    check f.matches(parseRecord(Relay))
    check LogFilter(enabled: true).matches(parseRecord(Relay))

  test "describe quotes values with spaces":
    check rule(lfMsg, opContains, "peer connections").describe == "msg contains \"peer connections\""
    check rule(lfKey, opEquals, "1", key = "peerId").describe == "peerId = 1"

suite "saved filters":
  test "JSON round trip":
    let f = filter(rule(lfLevel, opAtLeast, "WRN"),
                   rule(lfKey, opNotContains, "a b", jOr, key = "peerId"))
    let back = fromJson(f.toJson)
    check back.isOk
    check back.get.rules == f.rules
    check back.get.enabled
    check fromJson("{\"rules\": [{\"field\": \"nope\", \"op\": \"contains\"}]}").isErr
    check fromJson("not json").isErr

suite "a stream of lines":
  test "continuation lines follow their record":
    let lines = @[Relay, "  continued relay detail", Err, "  at node_host.nim(79)", "plain output"]
    let f = filter(rule(lfLevel, opAtLeast, "ERR"))
    var v: LineVerdicts
    var shown: seq[string]
    for l in lines:
      if v.pass(f, l): shown.add l
    check shown == @[Err, "  at node_host.nim(79)", "plain output"]
    check f.countMatches(lines) == 3
    check LogFilter().countMatches(lines) == lines.len
