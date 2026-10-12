## The node configuration as `LogosDeliveryNodeConf` (the logosdeliverynode
## command line: entry-layer, mode, the Messaging API flags and every kernel
## option) written as flat JSON with the CLI option names:
##
##   {"entry-layer": "channels", "mode": "Core", "preset": "logos.test",
##    "tcp-port": 60100, "reliability": true}
##
## The Node management view edits this JSON; the node is built from it with
## `LogosDelivery.new(LogosDeliveryNodeConf)`. This module holds the option
## catalog (from the conf types themselves, so it follows logos-delivery), the
## JSON loader, conversion from the `LogosDeliveryConf` JSON shapes, and
## patching single options.

{.push raises: [].}

import std/[json, macros, options, sets, strutils, tables, typetraits]
import results
import confutils, confutils/defs, confutils/std/net
import logos_delivery
import logos_delivery/waku/factory/waku_conf
import tools/confutils/[cli_args, conf_from_json]
import ./[conf_resolve, tui_brokers]

export cli_args.LogosDeliveryNodeConf

# --- option catalog -------------------------------------------------------------

const
  Excluded = ["config-file"] ## CLI-only: a TOML file to read more options from
  Secrets = ["nodekey", "rln-relay-cred-password", "rln-relay-eth-private-key", "mixkey"]

  Groups: seq[(string, seq[string])] = @[
    ("General", @["entry-layer", "mode", "preset", "cluster-id", "num-shards-in-network",
      "shard", "protected-shard", "content-topic", "max-msg-size", "agent-string",
      "local-storage-path", "log-level", "log-format", "nodekey"]),
    ("Messaging", @["reliability", "anonymity-level"]),
    ("Relay", @["relay", "relay-*", "staticnode", "entry-node"]),
    ("Discovery", @["discv5-*", "dns-discovery*", "peer-exchange*", "rendezvous",
      "enable-kad-discovery", "kad-*", "plugin-kad-discovery"]),
    ("Store", @["store*"]),
    ("Filter", @["filter*"]),
    ("Lightpush", @["lightpush*"]),
    ("RLN", @["rln-*"]),
    ("Mix", @["mix*"]),
    ("REST", @["rest*"]),
    ("Metrics", @["metrics-*"]),
    ("Network", @["listen-address", "tcp-port", "ports-shift", "nat*", "ext-multiaddr*",
      "dns4-domain-name", "dns-addrs-name-server", "max-connections", "relay-service-ratio",
      "ip-colocation-limit", "max-pure-libp2p-peers", "peer-store-capacity",
      "peer-persistence", "websocket-*", "quic-*", "rate-limit"]),
  ]

proc matches(cli, pattern: string): bool =
  if pattern.endsWith("*"):
    cli.startsWith(pattern[0 ..^ 2])
  else:
    cli == pattern

proc groupOf*(cli: string): string =
  ## Exact names first (so relay-service-ratio is Network, not Relay), then
  ## prefixes in Groups order.
  for (group, names) in Groups:
    if cli in names:
      return group
  for (group, names) in Groups:
    for p in names:
      if p.endsWith("*") and cli.matches(p):
        return group
  "Other"

proc display[T](v: T): string =
  ## A conf value as the tree shows it ("" = unset).
  when T is distinct:
    display(distinctBase(T)(v))
  elif T is Opt or T is Option:
    (if v.isSome: display(v.get) else: "")
  elif T is string:
    v
  elif T is seq:
    var items: seq[string]
    for item in v:
      items.add display(item)
    items.join(", ")
  elif compiles($v):
    try:
      $v
    except Exception:
      "?"
  else:
    "?"

template settable(V: typedesc): bool =
  ## What the JSON loader can set (conf_from_json.applyJsonFieldsToConf).
  when V is Opt:
    when typeof(default(V).get()) is seq:
      compiles(parseCmdArg(typeof(default(V).get()[0]), ""))
    else:
      compiles(parseCmdArg(typeof(default(V).get()), ""))
  elif V is seq:
    compiles(parseCmdArg(typeof(default(V)[0]), ""))
  else:
    compiles(parseCmdArg(V, ""))

proc describe[V](o: var NodeOption, v: V) =
  when V is Opt:
    var inner: typeof(v.get())
    describe(o, inner)
  elif V is bool:
    o.kind = NodeOptKind.Bool
    o.choices = @["true", "false"]
  elif V is enum:
    o.kind = NodeOptKind.Choice
    for e in V.low .. V.high:
      o.choices.add $e
  elif V is seq:
    o.kind = NodeOptKind.List
  else:
    o.kind = NodeOptKind.Text

proc addOptions[T](res: var seq[NodeOption], part: string, conf: T) =
  for fname, value in fieldPairs(conf):
    when value is MessagingNodeConf or value is WakuNodeConf:
      discard # the flattened parts, walked separately
    elif settable(typeof(value)):
      var o = NodeOption(field: fname, part: part)
      when value.hasCustomPragma(defs.name):
        o.cli = value.getCustomPragmaVal(defs.name)
      else:
        o.cli = fname
      when value.hasCustomPragma(defs.desc):
        o.desc = value.getCustomPragmaVal(defs.desc)
      o.describe(value)
      o.default = display(value)
      o.secret = o.cli in Secrets
      o.group = groupOf(o.cli)
      if o.cli notin Excluded:
        res.add o

proc defaultNodeConf(): Result[LogosDeliveryNodeConf, string] =
  defaultLogosDeliveryNodeConf()

proc nodeOptions*(): Result[seq[NodeOption], string] =
  ## Every option the node config JSON can set, with its default.
  let conf = ?defaultNodeConf()
  var res: seq[NodeOption]
  res.addOptions("top", conf)
  res.addOptions("messaging", conf.messaging)
  res.addOptions("kernel", conf.kernel)
  ok(res)

proc keysOf(o: NodeOption): seq[string] =
  @[o.cli.toLowerAscii, o.field.toLowerAscii]

# --- loading ---------------------------------------------------------------------

proc partNames[T](conf: T): HashSet[string] =
  for field, value in fieldPairs(conf):
    when not (value is MessagingNodeConf or value is WakuNodeConf):
      result.incl field.toLowerAscii
      when value.hasCustomPragma(defs.name):
        result.incl value.getCustomPragmaVal(defs.name).toLowerAscii

proc loadNodeConf*(text: string): Result[LogosDeliveryNodeConf, string] =
  ## The JSON as `LogosDeliveryNodeConf`: the CLI defaults, then each key
  ## applied by logos-delivery's own JSON rules (field or CLI name, any case).
  let node =
    try:
      parseJson(text)
    except CatchableError as e:
      return err("invalid JSON: " & e.msg)
  var fields = ?collectJsonFields(node)
  var conf = ?defaultNodeConf()
  let topNames = partNames(conf)
  let msgNames = partNames(conf.messaging)
  let kernelNames = partNames(conf.kernel)
  var top, msg, kernel: Table[string, (string, JsonNode)]
  var unknown: seq[string]
  for k, v in fields:
    if k in topNames: top[k] = v
    elif k in msgNames: msg[k] = v
    elif k in kernelNames: kernel[k] = v
    else: unknown.add v[0]
  if unknown.len > 0:
    return err("Unrecognized option(s): " & unknown.join(", "))
  ?applyJsonFieldsToConf(conf, top, "Failed to parse", "Unrecognized option(s)")
  ?applyJsonFieldsToConf(conf.messaging, msg, "Failed to parse", "Unrecognized option(s)")
  ?applyJsonFieldsToConf(conf.kernel, kernel, "Failed to parse", "Unrecognized option(s)")
  ok(conf)

proc validateNodeConf*(text: string): Result[LogosDeliveryNodeConf, string] =
  ## Loads, then runs the translation `LogosDelivery.new` runs, so a value the
  ## node would reject is caught here.
  let conf = ?loadNodeConf(text)
  let resolved = ?resolveCliConf(conf)
  discard ?WakuNodeConf(resolved.kernelConf).toWakuConf()
  ok(conf)

# --- converting LogosDeliveryConf JSON ----------------------------------------------

proc isLogosDeliveryConf(node: JsonNode): bool =
  ## Wrapper keys, or no entry layer at all (the layered / legacy flat shapes
  ## then mean the full stack, which `LogosDeliveryNodeConf` must say).
  for k in node.keys:
    if k.toLowerAscii in ["kernelconf", "messagingoverrides", "channelsoverrides"]:
      return true
  for k in node.keys:
    if k.toLowerAscii in ["entry-layer", "entrylayer"]:
      return false
  true

proc toNodeConfJson*(text: string): Result[tuple[json, message: string], string] =
  ## Node config JSON for `text`: as is when it already is one, else
  ## converted from a `LogosDeliveryConf` shape. `message` lists what had no
  ## place in `LogosDeliveryNodeConf` ("" when nothing was dropped).
  let node =
    try:
      parseJson(text)
    except CatchableError as e:
      return err("invalid JSON: " & e.msg)
  if node.kind != JObject:
    return err("the config must be a JSON object")
  if not node.isLogosDeliveryConf:
    discard ?loadNodeConf(text)
    return ok((json: node.pretty & "\n", message: ""))

  let opts = ?nodeOptions()
  var known: HashSet[string]
  for o in opts:
    for k in o.keysOf:
      known.incl k
  var res = newJObject()
  var dropped: seq[string]
  proc lift(src: JsonNode, path: string) =
    for k, v in src:
      if k.toLowerAscii in known:
        res[k] = v
      else:
        dropped.add path & k

  case node.shapeOf
  of ConfShape.Kernel:
    res["entry-layer"] = %"kernel"
    for k, v in node:
      if k.toLowerAscii == "kernelconf" and v.kind == JObject:
        lift(v, "kernelConf.")
      elif k.toLowerAscii notin ["entrylayer", "mode"]:
        dropped.add k
  of ConfShape.Layered:
    res["entry-layer"] = %"channels"
    for k, v in node:
      case k.toLowerAscii
      of "entrylayer":
        res["entry-layer"] = v
      of "preset", "mode":
        res[k] = v
      of "messagingoverrides":
        if v.kind == JObject:
          lift(v, "messagingOverrides.")
      of "channelsoverrides":
        if v.kind == JObject:
          for ck in v.keys:
            dropped.add "channelsOverrides." & ck
      else:
        dropped.add k
  of ConfShape.Flat:
    res["entry-layer"] = %"channels"
    lift(node, "")

  let outJson = res.pretty & "\n"
  discard ?loadNodeConf(outJson)
  ok((
    json: outJson,
    message:
      if dropped.len == 0: ""
      else: "not carried over (no LogosDeliveryNodeConf option): " & dropped.join(", "),
  ))

# --- rows and patching ----------------------------------------------------------------

proc jsonDisplay(v: JsonNode): string =
  case v.kind
  of JString: v.getStr
  of JArray:
    var items: seq[string]
    for i in v:
      items.add (if i.kind == JString: i.getStr else: $i)
    items.join(", ")
  else: $v

proc findOptKey(obj: JsonNode, o: NodeOption): seq[string] =
  ## The keys in `obj` that set `o` (field or CLI name, any case).
  for k in obj.keys:
    if k.toLowerAscii in o.keysOf:
      result.add k

proc nodeOptionRows*(text: string): Result[seq[NodeOptionRow], string] =
  ## Every option with the value the JSON sets, or its default.
  let node =
    try:
      parseJson(text)
    except CatchableError as e:
      return err("invalid JSON: " & e.msg)
  if node.kind != JObject:
    return err("the config must be a JSON object")
  var rows: seq[NodeOptionRow]
  for o in ?nodeOptions():
    var row = NodeOptionRow(opt: o, value: o.default, source: "default")
    let keys = node.findOptKey(o)
    if keys.len > 0:
      row.value = jsonDisplay(node{keys[0]})
      row.source = "json"
    if o.secret and row.value.len > 0:
      row.value = "<hidden>"
    rows.add row
  ok(rows)

proc patchNodeConf*(
    text, cli, valueJson: string, append = false, reset = false
): Result[tuple[json, message: string], string] =
  ## Sets (append: adds one list item; reset: removes) the option `cli` in the
  ## node config JSON. The result must pass `validateNodeConf`.
  let node =
    try:
      parseJson(text)
    except CatchableError as e:
      return err("the config is not valid JSON: " & e.msg)
  if node.kind != JObject:
    return err("the config must be a JSON object")
  var opt: NodeOption
  for o in ?nodeOptions():
    if cli.toLowerAscii in o.keysOf:
      opt = o
  if opt.cli.len == 0:
    return err(cli & " is not a node config option")

  let existing = node.findOptKey(opt)
  for k in existing[min(1, existing.len) .. ^1]:
    try:
      node.delete(k)
    except KeyError:
      discard
  let key = if existing.len > 0: existing[0] else: opt.cli
  var message: string
  if reset:
    if node.hasKey(key):
      try:
        node.delete(key)
      except KeyError:
        discard
    message = opt.cli & " reset to default"
  else:
    let value =
      try:
        parseJson(valueJson)
      except CatchableError as e:
        return err("bad value: " & e.msg)
    if append:
      var list = newJArray()
      if node.hasKey(key) and node{key}.kind == JArray:
        list = node{key}
      if value notin list.getElems:
        list.add value
      node[key] = list
      message = "added to " & key
    else:
      node[key] = value
      message = "set " & key

  let outJson = node.pretty & "\n"
  let check = validateNodeConf(outJson)
  if check.isErr:
    return err("not applied — the node would reject it: " & check.error)
  ok((json: outJson, message: message))

{.pop.}
