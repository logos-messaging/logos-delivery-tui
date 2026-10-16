## Effective node configuration (with the source of each value) and the
## network presets, for the configuration views.
##
## The node config JSON (preset, mode, entryLayer, *Overrides / kernelConf /
## flat) is only the input: logos-delivery merges the preset when it builds
## the kernel config (`WakuNodeConf.toWakuConf`, which `LogosDelivery.new`
## runs first). This module builds that same `WakuConf` to show what the node
## actually uses, and tells where each value comes from.

{.push raises: [].}

import std/[json, options, sets, strutils, tables]
import results, stint
import logos_delivery
import logos_delivery/api/conf/[logos_delivery_conf_json, channels_conf, messaging_conf]
import logos_delivery/waku/factory/[waku_conf, networks_config]
import tools/confutils/cli_args
import ./[conf_flatten, tui_brokers]

const PresetNames* = ["logos.test", "logos.dev", "twn", "status.prod", "status.staging"]
  ## The names `toNetworkPresetConf` accepts (cli_args.nim); not exported there.

type ConfShape* {.pure.} = enum
  Layered ## preset / mode / entryLayer / messagingOverrides / channelsOverrides
  Kernel ## entryLayer kernel + kernelConf
  Flat ## legacy: WakuNodeConf keys at the top level

# --- shape -----------------------------------------------------------------------

proc topKeys(node: JsonNode): HashSet[string] =
  for k in node.keys:
    result.incl k.toLowerAscii

proc shapeOf*(node: JsonNode): ConfShape =
  let keys = node.topKeys
  if "kernelconf" in keys:
    return ConfShape.Kernel
  if node.hasKey("entryLayer") and node{"entryLayer"}.kind == JString and
      node{"entryLayer"}.getStr.toLowerAscii == "kernel":
    return ConfShape.Kernel
  for k in keys:
    if k notin ["preset", "mode", "entrylayer", "messagingoverrides", "channelsoverrides"].toHashSet:
      return ConfShape.Flat
  ConfShape.Layered

proc findKey(node: JsonNode, key: string): string =
  ## Existing key in `node` matching `key` case-insensitively ("" if none).
  for k in node.keys:
    if k.cmpIgnoreCase(key) == 0:
      return k
  ""

# --- building the kernel config ------------------------------------------------------

proc buildWakuConf(confJson: string): Result[WakuConf, string] =
  let conf = ?parseLogosDeliveryConf(confJson)
  WakuNodeConf(conf.kernelConf).toWakuConf()

proc presetOnlyJson(node: JsonNode, withPreset: bool): JsonNode =
  ## The user's config reduced to what selects defaults: preset and mode for
  ## the layered / flat shapes, preset inside kernelConf for the kernel shape.
  result = newJObject()
  case node.shapeOf
  of ConfShape.Kernel:
    result["entryLayer"] = %"kernel"
    var kc = newJObject()
    let kk = node.findKey("kernelConf")
    if withPreset and kk.len > 0 and node{kk}.kind == JObject:
      let pk = node{kk}.findKey("preset")
      if pk.len > 0:
        kc["preset"] = node{kk}{pk}
    result["kernelConf"] = kc
  of ConfShape.Layered, ConfShape.Flat:
    for key in ["mode", "entryLayer"]:
      let k = node.findKey(key)
      if k.len > 0:
        result[key] = node{k}
    if withPreset:
      let pk = node.findKey("preset")
      if pk.len > 0:
        result["preset"] = node{pk}

# --- effective rows ---------------------------------------------------------------------

proc hidden(key: string): bool =
  let k = key.toLowerAscii
  for secret in ["nodekey", "password", "privatekey", "creds", "mixkey"]:
    if secret in k:
      return true
  false

proc flatRows(c: WakuConf): Table[string, string] =
  var rows: seq[FlatKV]
  flattenInto(rows, "kernel", c)
  for (k, v) in rows:
    result[k] = v

proc sourcedRows*(
    effective, built: WakuConf,
    presetOnly, noPreset: Result[WakuConf, string],
    messaging: Opt[MessagingClientConf],
    channels: Opt[ReliableChannelManagerConf],
): seq[KV] =
  ## The effective kernel config row by row, each with its source, then the
  ## messaging / channels layers. `built` is what the user's config builds
  ## to, `presetOnly` / `noPreset` the same config reduced to its preset /
  ## to nothing (both keep the entry layer and mode).
  let fromConfig = flatRows(built)
  let withPreset = if presetOnly.isOk: flatRows(presetOnly.get) else: initTable[string, string]()
  let defaults = if noPreset.isOk: flatRows(noPreset.get) else: initTable[string, string]()
  var flat: seq[FlatKV]
  flattenInto(flat, "kernel", effective)
  for (k, v) in flat:
    var row = KV(key: k, value: v)
    if k.hidden:
      row.value = "<hidden>"
    elif presetOnly.isOk and noPreset.isOk:
      # A key missing from a build (e.g. shardingConf.shards without a preset,
      # where sharding is static) differs from it.
      template differs(t: Table[string, string]): bool =
        k notin t or t.getOrDefault(k) != v
      row.source =
        if differs(fromConfig): "runtime"
        elif differs(withPreset): "config"
        elif differs(defaults): "preset"
        else: "default"
    result.add row
  flat.setLen(0)
  flattenInto(flat, "messaging", messaging)
  flattenInto(flat, "channels", channels)
  for (k, v) in flat:
    result.add KV(key: k, value: if k.hidden: "<hidden>" else: v)

proc effectiveRows*(
    confJson: string, running: WakuConf = nil
): Result[seq[KV], string] =
  ## `sourcedRows` for a LogosDeliveryConf JSON: the running node's config
  ## when given, else built from `confJson` exactly as LogosDelivery.new does.
  let node =
    try:
      parseJson(confJson)
    except CatchableError as e:
      return err("invalid JSON: " & e.msg)
  if node.kind != JObject:
    return err("configuration JSON must be an object")
  let parsed = ?parseLogosDeliveryConf(confJson)
  let built = ?WakuNodeConf(parsed.kernelConf).toWakuConf()
  ok(sourcedRows(
    (if running.isNil: built else: running), built,
    buildWakuConf($presetOnlyJson(node, withPreset = true)),
    buildWakuConf($presetOnlyJson(node, withPreset = false)),
    parsed.messagingConf, parsed.channelsConf,
  ))

proc appliedPreset*(n: WakuNodeConf): string =
  ## The preset the kernel config build applies (cli_args.toNetworkPresetConf):
  ## cluster-id 1 selects twn whatever `preset` says.
  if n.clusterId.isSome and n.clusterId.get == 1:
    return "twn"
  case n.preset.strip.toLowerAscii
  of "logosdev": "logos.dev"
  of "logostest": "logos.test"
  of "statusprod": "status.prod"
  of "statusstaging": "status.staging"
  else: n.preset.strip.toLowerAscii

proc presetOf*(confJson: string): string =
  ## The preset a LogosDeliveryConf JSON's node uses ("" if none).
  let parsed = parseLogosDeliveryConf(confJson)
  if parsed.isErr: "" else: appliedPreset(WakuNodeConf(parsed.get.kernelConf))

# --- presets -----------------------------------------------------------------------------

proc field(cfgKey, label: string, value: JsonNode): PresetField =
  PresetField(
    cfgKey: cfgKey,
    label: label,
    value: (if value.kind == JString: value.getStr else: $value),
    cfgValue: $value,
  )

proc listField(cfgKey: string, items: seq[string]): PresetField =
  PresetField(
    cfgKey: cfgKey, label: cfgKey, isList: true, items: items, cfgValue: $(%items)
  )

proc presetFields*(p: NetworkPresetConf): seq[PresetField] =
  result.add field("cluster-id", "cluster-id", %p.clusterId.int)
  case p.shardingConf.kind
  of AutoSharding:
    let shards = p.shardingConf.shards
    var contiguous = true # 0 .. n-1: the shard count says it all
    for i, s in shards:
      contiguous = contiguous and s.int == i
    if contiguous:
      result.add field("num-shards-in-network", "num-shards-in-network", %shards.len)
    else:
      var items: seq[string]
      for s in shards:
        items.add $s
      result.add PresetField(
        cfgKey: "autosharding-shards", label: "autosharding-shards", isList: true,
        items: items, cfgValue: $(%shards),
      )
  of StaticSharding:
    result.add field("", "sharding", %"static")
  result.add field("max-msg-size", "max-msg-size", %p.maxMessageSize)
  result.add field("max-pure-libp2p-peers", "max-pure-libp2p-peers", %p.maxPureLibp2pPeers)
  result.add field("reliability", "reliability", %p.p2pReliability)
  result.add field("discv5-discovery", "discv5-discovery", %p.discv5Discovery)
  result.add field("enable-kad-discovery", "enable-kad-discovery", %p.enableKadDiscovery)
  result.add field("mix", "mix", %p.mix)
  result.add field("rln-relay", "rln-relay", %p.rlnRelay)
  result.add field("rln-relay-dynamic", "rln-relay-dynamic", %p.rlnRelayDynamic)
  result.add field(
    "rln-relay-eth-contract-address", "rln-relay-eth-contract-address",
    %p.rlnRelayEthContractAddress,
  )
  result.add field("rln-relay-chain-id", "rln-relay-chain-id", %($p.rlnRelayChainId))
  result.add field("rln-relay-epoch-sec", "rln-relay-epoch-sec", %p.rlnEpochSizeSec)
  result.add field(
    "rln-relay-user-message-limit", "rln-relay-user-message-limit",
    %p.rlnRelayUserMessageLimit,
  )
  result.add listField("entry-node", p.entryNodes)
  result.add listField("mixnode", p.mixnodes)
  result.add listField("kad-bootstrap-node", p.kadBootstrapNodes)
  result.add listField("discv5-bootstrap-node", p.discv5BootstrapNodes)

proc presets*(): seq[PresetInfo] =
  for name in PresetNames:
    let p = toNetworkPresetConf(name, Opt.none(uint16))
    if p.isOk and p.get.isSome:
      result.add PresetInfo(name: name, fields: presetFields(p.get.get))

proc activePreset*(confJson: string): string =
  ## The preset named by the config ("" if none or unreadable).
  try:
    let node = parseJson(confJson)
    if node.kind != JObject:
      return ""
    var holder = node
    if node.shapeOf == ConfShape.Kernel:
      let kk = node.findKey("kernelConf")
      if kk.len == 0:
        return ""
      holder = node{kk}
    let pk = holder.findKey("preset")
    if pk.len > 0 and holder{pk}.kind == JString:
      return holder{pk}.getStr.strip.toLowerAscii
  except CatchableError:
    discard
  ""

{.pop.}
