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
    cfgKey*: string ## config JSON key (CLI name) when copyable, else ""
    cfgValue*: string ## that key's value as JSON text

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
  proc TuiCurrentConfig*(confJson: string): Result[seq[KV], string]
    ## The running node's effective config; when stopped, the one `confJson`
    ## (the editor's text) would give.

RequestBroker(sync):
  proc TuiPresets*(): Result[seq[PresetInfo], string]

RequestBroker(sync):
  proc TuiActivePreset*(confJson: string): Result[string, string]
    ## The preset named by `confJson` ("" if none).

RequestBroker(sync):
  proc TuiPatchConfig*(
    confJson: string, cfgKey: string, valueJson: string, append: bool
  ): Result[ConfigPatch, string]
    ## Puts `cfgKey` = `valueJson` where the config's shape keeps it, checked
    ## with the node's own config parser.

RequestBroker(sync):
  proc TuiConfigJson*(): Result[string, string]
    ## The node config JSON the host was given (or last applied).

RequestBroker:
  proc TuiNodeStart*(confJson: string): Future[Result[void, string]] {.async.}
    ## Empty `confJson` starts with the current config.

RequestBroker:
  proc TuiNodeStop*(): Future[Result[void, string]] {.async.}

RequestBroker:
  proc TuiNodeRestart*(confJson: string): Future[Result[void, string]] {.async.}
    ## Empty `confJson` restarts with the current config.

RequestBroker:
  proc TuiRunScenario*(path: string): Future[Result[void, string]] {.async.}
    ## Starts the scenario in the background; progress via TuiScenarioProgress.

RequestBroker:
  proc TuiStopScenario*(): Future[Result[void, string]] {.async.}

{.pop.}
