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
    peers*: int
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

RequestBroker:
  proc TuiHealthSnapshot*(): Future[Result[HealthSnapshot, string]] {.async.}

RequestBroker:
  proc TuiDisconnectPeer*(peerId: string): Future[Result[void, string]] {.async.}

RequestBroker:
  proc TuiDisconnectAll*(): Future[Result[void, string]] {.async.}

RequestBroker:
  proc TuiDialPeer*(multiaddr: string): Future[Result[void, string]] {.async.}

RequestBroker(sync):
  proc TuiCurrentConfig*(): Result[seq[KV], string]

RequestBroker(sync):
  proc TuiConfigJson*(): Result[string, string]
    ## The node config JSON the host was given (or last applied).

RequestBroker:
  proc TuiNodeStart*(): Future[Result[void, string]] {.async.}

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
