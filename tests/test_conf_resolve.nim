import std/[json, strutils]
import unittest2, results
import ../src/control/[conf_resolve, tui_brokers]

const Layered = """{
  "preset": "logos.test",
  "mode": "Core",
  "messagingOverrides": {"tcp-port": 60100, "nat": "none"}
}"""

proc row(rows: seq[KV], key: string): KV =
  for r in rows:
    if r.key == key:
      return r
  raiseAssert "no row " & key

suite "effective config":
  test "preset values appear, with their source":
    let rows = effectiveRows(Layered).get()
    check:
      row(rows, "kernel.clusterId").value == "2"
      row(rows, "kernel.clusterId").source == "preset"
      row(rows, "kernel.shardingConf.shards").value == "@[0, 1, 2, 3, 4, 5, 6, 7]"
      row(rows, "kernel.shardingConf.shards").source == "preset"
      row(rows, "kernel.endpointConf.p2pTcpPort").value == "60100"
      row(rows, "kernel.endpointConf.p2pTcpPort").source == "config"
      row(rows, "kernel.relay").source == "default"
      row(rows, "kernel.nodeKey").value == "<hidden>"

  test "messaging layer rows follow the kernel rows":
    let rows = effectiveRows(Layered).get()
    var sawMessaging = false
    for r in rows:
      if r.key.startsWith("messaging."):
        sawMessaging = true
    check sawMessaging

  test "bad config is an error":
    check effectiveRows("{").isErr
    check effectiveRows("""{"preset": "nope"}""").isErr

suite "presets":
  test "all presets with their lists":
    let ps = presets()
    check ps.len == 5
    var test: PresetInfo
    for p in ps:
      if p.name == "logos.test":
        test = p
    check test.name == "logos.test"
    var entry: PresetField
    for f in test.fields:
      if f.cfgKey == "entry-node":
        entry = f
    check:
      entry.isList
      entry.items.len == 6
      parseJson(entry.cfgValue).len == 6

  test "shards: a count for 0 .. n-1, the list otherwise":
    proc keys(p: PresetInfo): seq[string] =
      for f in p.fields:
        result.add f.cfgKey
    var test, status: PresetInfo
    for p in presets():
      if p.name == "logos.test": test = p
      elif p.name == "status.prod": status = p
    check:
      "num-shards-in-network" in test.keys
      "autosharding-shards" notin test.keys
      "num-shards-in-network" notin status.keys
    for f in status.fields:
      if f.cfgKey == "autosharding-shards":
        check:
          f.isList
          f.items == @["32"]
          f.cfgValue == "[32]"

  test "active preset by shape":
    check:
      activePreset(Layered) == "logos.test"
      activePreset("""{"entryLayer":"kernel","kernelConf":{"preset":"twn"}}""") == "twn"
      activePreset("""{"cluster-id": 3}""") == ""
      activePreset("not json") == ""

suite "preset in use":
  test "named preset, and cluster-id 1 overriding it":
    check:
      presetOf(Layered) == "logos.test"
      presetOf("""{"entryLayer":"kernel","kernelConf":{"preset":"twn"}}""") == "twn"
      presetOf("""{"cluster-id": 3}""") == ""
      presetOf("""{"cluster-id": 1}""") == "twn"
      presetOf("""{"preset": "logos.test", "cluster-id": 2}""") == "logos.test"
      presetOf("not json") == ""
