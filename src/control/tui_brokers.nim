## App-level broker contract between the view (illview) and the control layer.
## The view and the headless runner only talk to controllers through these
## brokers, on `tuiCtx`. Controllers listen to logos-delivery's own brokers on
## `ld.waku.brokerCtx`. Everything here is single-thread (one chronos loop).

{.push raises: [].}

import chronos, results
import brokers/[broker_context, event_broker, request_broker]

export chronos, results, broker_context, event_broker, request_broker

let tuiCtx* = NewBrokerContext()
  ## Our own scope, separate from the node's `waku.brokerCtx`.

type
  NodeState* {.pure.} = enum
    Stopped, Starting, Running, Stopping, Failed

  ChatDir* {.pure.} = enum
    Outgoing = "→"
    Incoming = "←"

  ChatStatus* {.pure.} = enum
    Pending = "…"
    Queued = "queued"
    Sent = "sent ✓"
    Propagated = "propagated ✓✓"
    Error = "error ✗"
    Live = "live"
    History = "history"

  MeshEntry* = object
    shard*: string
    peers*: int

  KV* = object
    key*: string
    value*: string
    source*: string ## runtime | config | preset | default | "" (unknown)

  PresetField* = object
    cfgKey*: string ## CLI name; "" = informational only
    label*: string
    value*: string ## display value (scalars)
    cfgValue*: string ## JSON text for cfgKey
    items*: seq[string] ## list fields: one entry per item
    isList*: bool

  PresetInfo* = object
    name*: string
    fields*: seq[PresetField]

  ConfigPatch* = object
    json*: string ## the patched config JSON, pretty-printed
    message*: string

  NodeOptKind* {.pure.} = enum
    Bool
    Choice ## an enum: one of `choices`
    List
    Text

  NodeOption* = object
    ## One `LogosDeliveryNodeConf` option (node_conf.nim).
    cli*: string ## CLI / JSON name
    field*: string ## Nim field name (also accepted in JSON)
    part*: string ## top | messaging | kernel
    group*: string ## for the tree
    desc*: string
    kind*: NodeOptKind
    choices*: seq[string]
    default*: string ## display form; "" = unset
    secret*: bool

  NodeOptionRow* = object
    opt*: NodeOption
    value*: string ## display form
    source*: string ## json | default

  HostConf* = object
    json*: string
    nodeConf*: bool ## a LogosDeliveryNodeConf JSON (Node management)

  StartedConfig* = object
    ## The configuration of the node last started (Current configuration).
    started*: bool ## false: no node has been started yet
    running*: bool
    json*: string ## exactly the JSON it was started from
    nodeConf*: bool ## that JSON is a LogosDeliveryNodeConf
    preset*: string ## the preset its config build applied; "" = none
    rows*: seq[KV] ## its effective config, with sources
    error*: string ## the rows could not be built

  PeerRow* = object
    protocol*: string
    peerId*: string
    addresses*: string

  ProtocolHealthRow* = object
    protocol*: string
    health*: string
    desc*: string

  TopicRow* = object
    shard*: string
    contentTopic*: string
    health*: string

  SelfInfo* = object
    peerId*: string
    addrs*: seq[string] ## announced multiaddrs
    protocols*: seq[string] ## mounted protocol codecs

  HealthSnapshot* = object
    connectionStatus*: string
    nodeHealth*: string
    protocols*: seq[ProtocolHealthRow]
    peers*: seq[PeerRow]
    topics*: seq[TopicRow]

EventBroker:
  type TuiNodeState* = object
    state*: NodeState
    info*: string ## error text, or the node's peer id once running

EventBroker:
  type TuiStats* = object
    sent*: int
    propagated*: int
    received*: int
    seen*: int ## relay-level traffic (MessageSeenEvent), shown as "relayed"
    errors*: int
    network*: string ## preset name when one is in use, else "cluster <id>"
    mode*: string ## Core | Edge; "" for the kernel layer (no mode)
    layer*: string ## mounted entry layer: kernel | messaging | channels
    peerStore*: int ## peers known to the peer store
    peers*: int ## connected peers
    mesh*: seq[MeshEntry]
    health*: string
    connStatus*: string
    peerId*: string
    logLevel*: string

EventBroker:
  type TuiChatLine* = object
    key*: string ## requestId (outgoing) or message hash (incoming)
    dir*: ChatDir
    contentTopic*: string
    text*: string
    status*: ChatStatus
    ts*: string

EventBroker:
  type TuiScenarioProgress* = object
    running*: bool
    step*: int
    total*: int
    msg*: string

RequestBroker:
  proc TuiSend*(
    contentTopic: string, payload: seq[byte], ephemeral: bool
  ): Future[Result[string, string]] {.async.}

RequestBroker:
  proc TuiSubscribe*(contentTopic: string): Future[Result[void, string]] {.async.}

RequestBroker:
  proc TuiUnsubscribe*(contentTopic: string): Future[Result[void, string]] {.async.}

RequestBroker(sync):
  proc TuiSetLogLevel*(level: string): Result[void, string]

RequestBroker(sync):
  proc TuiSelfInfo*(): Result[SelfInfo, string]

RequestBroker:
  proc TuiHealthSnapshot*(): Future[Result[HealthSnapshot, string]] {.async.}

RequestBroker:
  proc TuiDisconnectPeer*(peerId: string): Future[Result[void, string]] {.async.}

RequestBroker:
  proc TuiDisconnectAll*(): Future[Result[void, string]] {.async.}

RequestBroker:
  proc TuiDialPeer*(multiaddr: string): Future[Result[void, string]] {.async.}

RequestBroker(sync):
  proc TuiStartedConfig*(): Result[StartedConfig, string]
    ## The config of the running (or last started) node.

RequestBroker(sync):
  proc TuiPresets*(): Result[seq[PresetInfo], string]

RequestBroker(sync):
  proc TuiActivePreset*(confJson: string): Result[string, string]
    ## The preset named by `confJson` ("" if none).

RequestBroker(sync):
  proc TuiConfigJson*(): Result[HostConf, string]
    ## The node config JSON the host was given (or last applied).

RequestBroker(sync):
  proc TuiNodeOptions*(confJson: string): Result[seq[NodeOptionRow], string]
    ## Every LogosDeliveryNodeConf option with the value `confJson` sets, or
    ## its default.

RequestBroker(sync):
  proc TuiNodeConfPatch*(
    confJson: string, cli: string, valueJson: string, append: bool, reset: bool
  ): Result[ConfigPatch, string]
    ## Sets / appends to / resets one option of a LogosDeliveryNodeConf JSON,
    ## checked with the node's own translation.

RequestBroker(sync):
  proc TuiNodeConfFrom*(text: string): Result[ConfigPatch, string]
    ## `text` as LogosDeliveryNodeConf JSON (converted from a LogosDeliveryConf
    ## shape when needed; `message` lists what was dropped).

RequestBroker:
  proc TuiNodeStart*(
    confJson: string, nodeConf: bool
  ): Future[Result[void, string]] {.async.}
    ## Empty `confJson` starts with the current config. `nodeConf`: the JSON is
    ## a LogosDeliveryNodeConf (else a LogosDeliveryConf).

RequestBroker:
  proc TuiNodeStop*(): Future[Result[void, string]] {.async.}

RequestBroker:
  proc TuiNodeRestart*(
    confJson: string, nodeConf: bool
  ): Future[Result[void, string]] {.async.}
    ## Empty `confJson` restarts with the current config.

RequestBroker:
  proc TuiRunScenario*(path: string): Future[Result[void, string]] {.async.}
    ## Starts the scenario in the background; progress via TuiScenarioProgress.

RequestBroker:
  proc TuiStopScenario*(): Future[Result[void, string]] {.async.}

{.pop.}
