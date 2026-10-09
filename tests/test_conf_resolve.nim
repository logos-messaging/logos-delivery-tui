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
      row(rows, "kernel.shardingConf.numShardsInCluster").value == "8"
      row(rows, "kernel.shardingConf.numShardsInCluster").source == "preset"
      row(rows, "kernel.endpointConf.p2pTcpPort").value == "60100"
      row(rows, "kernel.endpointConf.p2pTcpPort").source == "config"
      row(rows, "kernel.relay").source == "default"
      row(rows, "kernel.nodeKey").value == "<hidden>"

  test "copyable rows carry the config key and JSON value":
    let rows = effectiveRows(Layered).get()
    check:
      row(rows, "kernel.clusterId").cfgKey == "kernel:cluster-id"
      row(rows, "kernel.clusterId").cfgValue == "2"
      row(rows, "kernel.maxMessageSizeBytes").cfgValue == "\"153600B\""
      row(rows, "kernel.nodeKey").cfgKey == ""
      # found by name: top level, and stem + leaf inside a nested …Conf
      row(rows, "kernel.relay").cfgKey == "kernel:relay"
      row(rows, "kernel.discv5Conf.bitsPerHop").cfgKey == "kernel:discv5-bits-per-hop"
      row(rows, "kernel.filterServiceConf.maxCriteria").cfgKey == "kernel:filter-max-criteria"
      row(rows, "kernel.staticNodes").cfgValue.startsWith("[\"/dns4/")
      row(rows, "messaging.p2pTcpPort").cfgKey == "messaging:tcp-port"

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
    check ps.len == 4
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

  test "active preset by shape":
    check:
      activePreset(Layered) == "logos.test"
      activePreset("""{"entryLayer":"kernel","kernelConf":{"preset":"twn"}}""") == "twn"
      activePreset("""{"cluster-id": 3}""") == ""
      activePreset("not json") == ""

suite "patching the config JSON":
  test "layered: kernel-mirrored keys go to messagingOverrides":
    let p = patchConfig(Layered, "cluster-id", "5").get()
    let j = parseJson(p.json)
    check:
      j["messagingOverrides"]["cluster-id"].getInt == 5
      j["messagingOverrides"]["tcp-port"].getInt == 60100
      p.message == "set messagingOverrides.cluster-id"

  test "layered: a kernel-only key is refused, saying why":
    let r = patchConfig(Layered, "kernel:relay", "true")
    check:
      r.isErr
      "kernel-only" in r.error

  test "every copyable row of the kernel and flat shapes is accepted":
    for conf in [
      """{"entryLayer":"kernel","kernelConf":{"preset":"logos.test","logLevel":"INFO"}}""",
      """{"preset":"logos.test","logLevel":"INFO","tcp-port":60100}""",
    ]:
      for r in effectiveRows(conf).get():
        if r.cfgKey.len > 0:
          check patchConfig(conf, r.cfgKey, r.cfgValue).isOk

  test "an alias already in the config is reused, not set twice":
    let conf = """{"preset": "logos.test", "messagingOverrides": {"logLevel": "INFO"}}"""
    let p = patchConfig(conf, "kernel:log-level", "\"DEBUG\"").get()
    let m = parseJson(p.json)["messagingOverrides"]
    check:
      m["logLevel"].getStr == "DEBUG"
      not m.hasKey("log-level")

  test "messaging and channels rows go to their overrides":
    let m = parseJson(patchConfig(Layered, "messaging:reliability", "false").get().json)
    let c = parseJson(patchConfig(Layered, "channels:sdsMaxRetransmissions", "3").get().json)
    check:
      m["messagingOverrides"]["reliability"].getBool == false
      c["channelsOverrides"]["sdsMaxRetransmissions"].getInt == 3
      patchConfig("""{"cluster-id": 3}""", "channels:sdsMaxRetransmissions", "3").isErr

  test "preset key stays at the top level":
    let j = parseJson(patchConfig(Layered, "preset", "\"logos.dev\"").get().json)
    check j["preset"].getStr == "logos.dev"

  test "append adds a list item once":
    let item = "\"/dns4/a.example/tcp/30303/p2p/16Uiu2HAmQ9X2xDfPG3uL77V9piYDhjq14JhKCtcmNYsTMKNqrKCj\""
    let once = patchConfig(Layered, "entry-node", item, append = true).get()
    let twice = patchConfig(once.json, "entry-node", item, append = true).get()
    check:
      parseJson(once.json)["messagingOverrides"]["entry-node"].len == 1
      parseJson(twice.json)["messagingOverrides"]["entry-node"].len == 1

  test "flat shape writes at the top level":
    let flat = """{"cluster-id": 3, "relay": true}"""
    let p = patchConfig(flat, "relay", "false").get()
    check parseJson(p.json)["relay"].getBool == false

  test "kernel shape writes into kernelConf":
    let kernel = """{"entryLayer": "kernel", "kernelConf": {"preset": "logos.test"}}"""
    let p = patchConfig(kernel, "mix", "true").get()
    let j = parseJson(p.json)
    check:
      j["kernelConf"]["mix"].getBool
      p.message == "set kernelConf.mix"
    let pp = patchConfig(kernel, "preset", "\"twn\"").get()
    check parseJson(pp.json)["kernelConf"]["preset"].getStr == "twn"

  test "invalid editor JSON is refused":
    check patchConfig("{", "cluster-id", "1").isErr
