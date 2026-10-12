import std/[json, strutils]
import unittest2, results
import ../src/control/[node_conf, tui_brokers]

proc opt(rows: seq[NodeOptionRow], cli: string): NodeOptionRow =
  for r in rows:
    if r.opt.cli == cli:
      return r
  raiseAssert "no option " & cli

suite "node config options":
  test "the catalog covers all three parts, with kinds and groups":
    let opts = nodeOptions().get()
    var parts: seq[string]
    for o in opts:
      if o.part notin parts:
        parts.add o.part
      check o.cli != "config-file"
    check parts.len == 3
    let rows = nodeOptionRows("{}").get()
    check:
      opt(rows, "entry-layer").opt.kind == NodeOptKind.Choice
      "channels" in opt(rows, "entry-layer").opt.choices
      opt(rows, "relay").opt.kind == NodeOptKind.Bool
      opt(rows, "staticnode").opt.kind == NodeOptKind.List
      opt(rows, "tcp-port").opt.kind == NodeOptKind.Text
      opt(rows, "reliability").opt.part == "messaging"
      opt(rows, "discv5-udp-port").opt.group == "Discovery"
      opt(rows, "relay-service-ratio").opt.group == "Network"
      opt(rows, "tcp-port").source == "default"

  test "values from the JSON, by CLI or field name":
    let rows = nodeOptionRows("""{"tcp-port": 60100, "logLevel": "DEBUG"}""").get()
    check:
      opt(rows, "tcp-port").value == "60100"
      opt(rows, "tcp-port").source == "json"
      opt(rows, "log-level").value == "DEBUG"

suite "loading":
  test "a node config JSON loads into all parts":
    let c = loadNodeConf(
      """{"entry-layer":"channels","mode":"Edge","reliability":false,"tcp-port":60111}"""
    ).get()
    check:
      $c.entryLayer == "channels"
      c.messaging.reliabilityEnabled.get() == false
      c.kernel.tcpPort.int == 60111

  test "unknown keys are refused":
    check loadNodeConf("""{"messagingOverrides": {}}""").isErr

  test "validate runs the node's translation":
    check validateNodeConf("""{"entry-layer":"channels","preset":"logos.test"}""").isOk
    check validateNodeConf("""{"entry-layer":"kernel","mode":"Core"}""").isErr

suite "converting LogosDeliveryConf JSON":
  test "layered: overrides lifted, channels overrides reported":
    let r = toNodeConfJson("""{
      "preset": "logos.test", "mode": "Core",
      "messagingOverrides": {"logLevel": "INFO", "tcp-port": 60100, "send-queue-capacity": 5},
      "channelsOverrides": {"sdsMaxRetransmissions": 3}
    }""").get()
    let j = parseJson(r.json)
    check:
      j["entry-layer"].getStr == "channels"
      j["preset"].getStr == "logos.test"
      j["tcp-port"].getInt == 60100
      j["logLevel"].getStr == "INFO"
      not j.hasKey("send-queue-capacity")
      "messagingOverrides.send-queue-capacity" in r.message
      "channelsOverrides.sdsMaxRetransmissions" in r.message

  test "kernel shape":
    let j = parseJson(toNodeConfJson(
      """{"entryLayer":"kernel","kernelConf":{"preset":"twn","mix":true}}"""
    ).get().json)
    check:
      j["entry-layer"].getStr == "kernel"
      j["mix"].getBool

  test "preset + mode alone mean the full stack":
    let j = parseJson(toNodeConfJson("""{"preset":"logos.test","mode":"Core"}""").get().json)
    check j["entry-layer"].getStr == "channels"

  test "a node config JSON is kept":
    let src = """{"entry-layer":"messaging","tcp-port":1}"""
    let r = toNodeConfJson(src).get()
    check:
      parseJson(r.json) == parseJson(src)
      r.message == ""

suite "patching":
  const Base = """{"entry-layer": "channels", "preset": "logos.test", "logLevel": "INFO"}"""

  test "set, alias reuse, reset":
    let p = patchNodeConf(Base, "log-level", "\"DEBUG\"").get()
    let j = parseJson(p.json)
    check:
      j["logLevel"].getStr == "DEBUG"
      not j.hasKey("log-level")
    let r = patchNodeConf(p.json, "log-level", "", reset = true).get()
    check not parseJson(r.json).hasKey("logLevel")

  test "kernel-only options work with the full stack":
    let j = parseJson(patchNodeConf(Base, "relay", "false").get().json)
    check j["relay"].getBool == false

  test "append to a list once":
    let item = "\"/dns4/a.example/tcp/30303/p2p/16Uiu2HAmQ9X2xDfPG3uL77V9piYDhjq14JhKCtcmNYsTMKNqrKCj\""
    let once = patchNodeConf(Base, "staticnode", item, append = true).get()
    let twice = patchNodeConf(once.json, "staticnode", item, append = true).get()
    check parseJson(twice.json)["staticnode"].len == 1

  test "rejected values leave the JSON alone":
    check patchNodeConf(Base, "mode", "\"Core\"").isOk
    check patchNodeConf(Base, "tcp-port", "\"not a port\"").isErr
    check patchNodeConf(Base, "no-such-option", "1").isErr

  test "every option's default round-trips through the loader":
    for o in nodeOptions().get():
      if o.default.len == 0 or o.secret:
        continue
      let v =
        case o.kind
        of NodeOptKind.List: $(%o.default.split(", "))
        else: $(%o.default)
      check loadNodeConf("{" & $(%o.cli) & ": " & v & "}").isOk
