## Effective node configuration and network presets for the Configuration
## view, and patching values back into the node config JSON.
##
## The node config JSON (preset, mode, entryLayer, *Overrides / kernelConf /
## flat) is only the input: logos-delivery merges the preset when it builds
## the kernel config (`WakuNodeConf.toWakuConf`, which `LogosDelivery.new`
## runs first). This module builds that same `WakuConf` to show what the node
## actually uses, and tells where each value comes from.

{.push raises: [].}

import std/[json, macros, options, sets, strutils, tables, typetraits]
import results, stint
import confutils/defs
import logos_delivery
import logos_delivery/api/conf/[logos_delivery_conf_json, channels_conf]
import logos_delivery/waku/factory/[waku_conf, networks_config]
import tools/confutils/cli_args
import ./[conf_flatten, tui_brokers]

const PresetNames* = ["logos.test", "logos.dev", "twn", "status.prod"]
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

# --- config keys ---------------------------------------------------------------------

type CfgName = tuple[field, cli: string]

proc cfgNamesOf[T](conf: T): seq[CfgName] =
  ## The JSON keys `T` accepts: each field by its name or its CLI `name:`
  ## pragma, case-insensitively (the loader's rule, conf_from_json.nim).
  ## Takes a value: `hasCustomPragma` can't see through a typedesc generic.
  for field, value in fieldPairs(conf):
    when value.hasCustomPragma(defs.name):
      result.add((field, value.getCustomPragmaVal(defs.name)))
    else:
      result.add((field, field))

template cfgNames(T: typedesc): seq[CfgName] =
  cfgNamesOf(default(T))

proc lookup(names: seq[CfgName], key: string): int =
  ## Index of the field `key` names (by field or CLI name); -1 if none.
  for i, n in names:
    if n.field.cmpIgnoreCase(key) == 0 or n.cli.cmpIgnoreCase(key) == 0:
      return i
  -1

proc cfgJson[T](v: T): JsonNode =
  ## `v` as the JSON value the loader parses back into `T` (scalars go through
  ## `parseCmdArg` as strings); nil when it has no such form.
  when T is distinct:
    cfgJson(distinctBase(T)(v))
  elif T is Opt or T is Option:
    (if v.isSome: cfgJson(v.get) else: nil)
  elif T is bool:
    %v
  elif T is SomeSignedInt:
    %v.BiggestInt
  elif T is SomeUnsignedInt:
    (if v.uint64 <= BiggestInt.high.uint64: %v.BiggestInt else: %($v))
  elif T is SomeFloat:
    %v
  elif T is string:
    %v
  elif T is seq:
    let list = newJArray()
    for item in v:
      let j = cfgJson(item)
      if j.isNil or j.kind in {JArray, JObject}:
        return nil
      list.add j
    list
  elif compiles($v):
    try:
      %($v)
    except Exception:
      nil
  else:
    nil

# --- table row -> config key ---------------------------------------------------------------

proc explicitTargets(c: WakuConf): Table[string, (string, JsonNode)] =
  ## Effective values whose config key isn't found by name (see kernelTargets).
  if c.shardingConf.kind == AutoSharding:
    result["kernel.shardingConf.numShardsInCluster"] =
      ("num-shards-in-network", %c.shardingConf.numShardsInCluster.int)
  result["kernel.subscribeShards"] = ("shard", cfgJson(c.subscribeShards))
  result["kernel.maxMessageSizeBytes"] = ("max-msg-size", %($c.maxMessageSizeBytes & "B"))
  result["kernel.peerExchangeService"] = ("peer-exchange", %c.peerExchangeService)
  result["kernel.endpointConf.p2pTcpPort"] =
    ("tcp-port", %c.endpointConf.p2pTcpPort.int)
  result["kernel.endpointConf.p2pListenAddress"] =
    ("listen-address", %($c.endpointConf.p2pListenAddress))
  if c.rlnEvmConf.isSome:
    let r = c.rlnEvmConf.get
    result["kernel.rlnEvmConf.ethContractAddress"] =
      ("rln-relay-eth-contract-address", %r.ethContractAddress)
    result["kernel.rlnEvmConf.chainId"] = ("rln-relay-chain-id", %($r.chainId))
    result["kernel.rlnEvmConf.epochSizeSec"] = ("rln-relay-epoch-sec", %r.epochSizeSec)
    result["kernel.rlnEvmConf.userMessageLimit"] =
      ("rln-relay-user-message-limit", %r.userMessageLimit)
    result["kernel.rlnEvmConf.dynamic"] = ("rln-relay-dynamic", %r.dynamic)

proc stems(confField: string): seq[string] =
  ## Option-name prefixes for the fields of a nested `…Conf`:
  ## discv5Conf -> discv5, filterServiceConf -> filter, metricsServerConf ->
  ## metricsServer / metrics. endpointConf holds top-level options.
  if confField == "endpointConf":
    return @[""]
  for suffix in ["ServiceConf", "ServerConf", "Conf"]:
    if confField.endsWith(suffix):
      result.add confField[0 ..< confField.len - suffix.len]

proc kernelTargetsInto[T](
    res: var Table[string, (string, JsonNode)], names: seq[CfgName], key: string,
    prefixes: seq[string], v: T, depth = 0,
) =
  ## Mirrors flattenInto; at each leaf looks for the kernel option of the same
  ## name (top level) or `stem & Leaf` (inside a nested `…Conf`).
  when T is distinct:
    kernelTargetsInto(res, names, key, prefixes, distinctBase(T)(v), depth)
  elif T is Opt or T is Option:
    if v.isSome:
      kernelTargetsInto(res, names, key, prefixes, v.get, depth)
  elif T is ref:
    when ($T).endsWith("Conf"):
      if not v.isNil and depth < 6:
        for name, field in fieldPairs(v[]):
          kernelTargetsInto(res, names, key & "." & name, @[""], field, depth + 1)
  elif T is object and ($T).endsWith("Conf"):
    if depth < 6:
      let stems = key.rsplit('.', 1)[^1].stems
      for name, field in fieldPairs(v):
        kernelTargetsInto(res, names, key & "." & name, stems, field, depth + 1)
  else:
    let leaf = key.rsplit('.', 1)[^1]
    for stem in prefixes:
      let i = names.lookup(if stem.len == 0: leaf else: stem & leaf.capitalizeAscii)
      if i >= 0:
        let j = cfgJson(v)
        if not j.isNil:
          res[key] = (names[i].cli, j)
        return

proc kernelTargets(c: WakuConf): Table[string, (string, JsonNode)] =
  ## Effective path -> (kernel option, JSON value) for the values a config can set.
  kernelTargetsInto(result, cfgNames(WakuNodeConf), "kernel", @[""], c)
  for k, t in explicitTargets(c):
    if not t[1].isNil:
      result[k] = t

proc layerTargets[T](
    res: var Table[string, (string, JsonNode)], layer: string, conf: T
) =
  ## messaging.* / channels.* rows: their own override keys, 1:1.
  let names = cfgNamesOf(conf)
  for field, value in fieldPairs(conf):
    let j = cfgJson(value)
    if not j.isNil:
      res[layer & "." & field] = (names[names.lookup(field)].cli, j)

proc runningRows*(running: WakuConf): Result[seq[KV], string] =
  ## The running node's effective kernel config, without sources.
  var flat: seq[FlatKV]
  flattenInto(flat, "kernel", running)
  var rows: seq[KV]
  for (k, v) in flat:
    rows.add KV(key: k, value: if k.hidden: "<hidden>" else: v)
  ok(rows)

proc effectiveRows*(
    confJson: string, running: WakuConf = nil
): Result[seq[KV], string] =
  ## Rows of the effective kernel config (the running node's when given, else
  ## built from `confJson` exactly as LogosDelivery.new builds it), with the
  ## source of each value, followed by the messaging / channels layers.
  let node =
    try:
      parseJson(confJson)
    except CatchableError as e:
      return err("invalid JSON: " & e.msg)
  if node.kind != JObject:
    return err("configuration JSON must be an object")
  let parsed = ?parseLogosDeliveryConf(confJson)
  let built = ?WakuNodeConf(parsed.kernelConf).toWakuConf()
  let effective = if running.isNil: built else: running

  let eff = flatRows(effective)
  let fromConfig = flatRows(built)
  let presetOnly = buildWakuConf($presetOnlyJson(node, withPreset = true))
  let noPreset = buildWakuConf($presetOnlyJson(node, withPreset = false))
  let withPreset = if presetOnly.isOk: flatRows(presetOnly.get) else: initTable[string, string]()
  let defaults = if noPreset.isOk: flatRows(noPreset.get) else: initTable[string, string]()
  var targets = kernelTargets(effective)
  if parsed.messagingConf.isSome:
    layerTargets(targets, "messaging", parsed.messagingConf.get)
  if parsed.channelsConf.isSome:
    layerTargets(targets, "channels", parsed.channelsConf.get)

  var rows: seq[KV]
  var flat: seq[FlatKV]
  flattenInto(flat, "kernel", effective)
  for (k, v) in flat:
    var row = KV(key: k, value: v)
    if k.hidden:
      row.value = "<hidden>"
    elif presetOnly.isOk and noPreset.isOk:
      # A key missing from a build (e.g. numShardsInCluster without a preset,
      # where sharding is static) differs from it.
      template differs(t: Table[string, string]): bool =
        k notin t or t.getOrDefault(k) != v
      row.source =
        if differs(fromConfig): "runtime"
        elif differs(withPreset): "config"
        elif differs(defaults): "preset"
        else: "default"
    rows.add row

  flat.setLen(0)
  flattenInto(flat, "messaging", parsed.messagingConf)
  flattenInto(flat, "channels", parsed.channelsConf)
  for (k, v) in flat:
    rows.add KV(key: k, value: if k.hidden: "<hidden>" else: v)
  for row in rows.mitems:
    if not row.key.hidden and row.key in targets:
      let (cfgKey, value) = targets.getOrDefault(row.key)
      row.cfgKey = row.key.split('.', 1)[0] & ":" & cfgKey
      row.cfgValue = $value
  ok(rows)

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
    result.add field(
      "num-shards-in-network", "num-shards-in-network", %p.shardingConf.numShardsInCluster.int
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

# --- patching the config JSON -------------------------------------------------------------

proc child(node: JsonNode, key: string): (JsonNode, string) =
  ## `node[key]` (any case), created as an object if missing.
  var k = node.findKey(key)
  if k.len == 0:
    k = key
    node[k] = newJObject()
  (node{k}, k & ".")

proc destination(
    node: JsonNode, layer, key: string
): Result[(JsonNode, string, seq[CfgName]), string] =
  ## Where `layer`'s option `key` lives in this config's shape: the object, its
  ## path for messages, and the keys that object accepts.
  let shape = node.shapeOf
  if key == "preset" and shape != ConfShape.Kernel:
    return ok((node, "", newSeq[CfgName]()))
  case layer
  of "channels":
    if shape != ConfShape.Layered:
      return err("channels options go in channelsOverrides, which only the layered config (preset / mode / …Overrides) has")
    let (obj, path) = node.child("channelsOverrides")
    ok((obj, path, cfgNames(ReliableChannelManagerConf)))
  of "messaging":
    case shape
    of ConfShape.Layered:
      let (obj, path) = node.child("messagingOverrides")
      ok((obj, path, cfgNames(MessagingClientConf)))
    of ConfShape.Kernel:
      err("the messaging layer is not used with entryLayer kernel; set the kernel row instead")
    of ConfShape.Flat:
      ok((node, "", cfgNames(WakuNodeConf)))
  else: # kernel
    case shape
    of ConfShape.Layered:
      let names = cfgNames(MessagingClientConf)
      if key != "preset" and names.lookup(key) < 0:
        return err(
          key & " is kernel-only; messagingOverrides can't hold it (needs \"entryLayer\": \"kernel\")"
        )
      let (obj, path) = node.child("messagingOverrides")
      ok((obj, path, names))
    of ConfShape.Kernel:
      let (obj, path) = node.child("kernelConf")
      ok((obj, path, cfgNames(WakuNodeConf)))
    of ConfShape.Flat:
      ok((node, "", cfgNames(WakuNodeConf)))

proc patchConfig*(
    confJson, cfgKey, valueJson: string, append = false
): Result[tuple[json, message: string], string] =
  ## Sets the option `cfgKey` ("layer:key"; a bare key is a kernel option) to
  ## `valueJson` where this config's shape keeps it (append: add one item to a
  ## list value), then checks the result with the node's own config parser.
  ## The input is left alone when the parser rejects it.
  let node =
    try:
      parseJson(confJson)
    except CatchableError as e:
      return err("the config is not valid JSON: " & e.msg)
  if node.kind != JObject:
    return err("the config must be a JSON object")
  let value =
    try:
      parseJson(valueJson)
    except CatchableError as e:
      return err("bad value: " & e.msg)
  let (layer, cfg) =
    if ':' in cfgKey:
      let parts = cfgKey.split(':', 1)
      (parts[0], parts[1])
    else:
      ("kernel", cfgKey)

  let (obj, path, names) = ?node.destination(layer, cfg)
  # The loader takes a field by its name or its CLI name; reuse the one the
  # config already has and drop the other, or it is "set twice".
  var key = cfg
  let i = names.lookup(cfg)
  var existing: seq[string]
  for k in obj.keys:
    if k.cmpIgnoreCase(cfg) == 0 or
        (i >= 0 and (k.cmpIgnoreCase(names[i].field) == 0 or k.cmpIgnoreCase(names[i].cli) == 0)):
      existing.add k
  if existing.len > 0:
    key = existing[0]
    for k in existing[1 .. ^1]:
      try:
        obj.delete(k)
      except KeyError:
        discard

  if append:
    var list = newJArray()
    if obj.hasKey(key) and obj{key}.kind == JArray:
      list = obj{key}
    if value notin list.getElems:
      list.add value
    obj[key] = list
  else:
    obj[key] = value

  let text = node.pretty() & "\n"
  let check = parseLogosDeliveryConf(text)
  if check.isErr:
    return err("not applied — the node would reject it: " & check.error)
  ok((json: text, message: (if append: "added to " else: "set ") & path & key))

{.pop.}
