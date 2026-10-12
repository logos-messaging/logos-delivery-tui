## Owns the single in-process LogosDelivery instance: create / start / stop /
## restart from a JSON config: a `LogosDeliveryConf` (same shape as
## `logosdelivery_create_node` and the delivery-module `createNode`), or a
## `LogosDeliveryNodeConf` (Node management; see control/node_conf.nim). Controllers register attach/detach hooks
## so their logos-delivery listeners never outlive the node they closed over.

{.push raises: [].}

import std/strutils
import chronos, chronicles, results
import libp2p/peerid
import logos_delivery
import logos_delivery/waku/node/waku_node
import logos_delivery/waku/factory/waku_conf
import logos_delivery/api/conf/logos_delivery_conf_json
import ../control/[tui_brokers, node_conf]

export logos_delivery

logScope:
  topics = "ldtui host"

type
  AttachHook* = proc(ld: LogosDelivery) {.gcsafe, raises: [].}
    ## Called once the node has started; register listeners here.
  DetachHook* = proc(): Future[void] {.async: (raises: []).}
    ## Called before the node stops; drop listeners here.
  AfterCreateHook* = proc(ld: LogosDelivery) {.gcsafe, raises: [].}
    ## Called right after `LogosDelivery.new` (which re-runs `setupLog`).

  NodeHost* = ref object
    confJson*: string
    nodeConf*: bool ## confJson is a LogosDeliveryNodeConf JSON
    # The node last started successfully, kept after it stops: exactly the
    # JSON it was built from and the kernel config it ran with.
    startedJson*: string
    startedNodeConf*: bool
    startedConf*: WakuConf
    ld*: LogosDelivery
    state*: NodeState
    lastError*: string
    attachHooks: seq[AttachHook]
    detachHooks: seq[DetachHook]
    afterCreateHooks: seq[AfterCreateHook]

var gHost {.threadvar.}: NodeHost

proc host*(): NodeHost =
  if gHost.isNil:
    gHost = NodeHost(state: NodeState.Stopped, startedConf: nil) # WakuConf: requiresInit
  gHost

proc onAttach*(h: NodeHost, hook: AttachHook) =
  h.attachHooks.add hook

proc onDetach*(h: NodeHost, hook: DetachHook) =
  h.detachHooks.add hook

proc onAfterCreate*(h: NodeHost, hook: AfterCreateHook) =
  h.afterCreateHooks.add hook

proc setState(h: NodeHost, s: NodeState, info = "") =
  h.state = s
  TuiNodeState.emit(tuiCtx, TuiNodeState(state: s, info: info))

proc isRunning*(h: NodeHost): bool =
  h.state == NodeState.Running and not h.ld.isNil

proc peerIdStr*(h: NodeHost): string =
  if h.ld.isNil or h.ld.waku.isNil or h.ld.waku.node.isNil:
    return ""
  try:
    $h.ld.waku.node.peerId()
  except Exception:
    ""

proc fail(h: NodeHost, msg: string): Result[void, string] =
  h.lastError = msg
  error "node failure", error = msg
  h.setState(NodeState.Failed, msg)
  err(msg)

proc start*(
    h: NodeHost, confJson = "", nodeConf = false
): Future[Result[void, string]] {.async: (raises: []).} =
  ## A non-empty `confJson` becomes the node's config first; `nodeConf` says
  ## which kind it is.
  if h.state in {NodeState.Starting, NodeState.Running, NodeState.Stopping}:
    return err("node is " & $h.state)
  if confJson.strip.len > 0:
    h.confJson = confJson
    h.nodeConf = nodeConf
  if h.confJson.strip.len == 0:
    return h.fail("no node configuration given")
  h.setState(NodeState.Starting)

  # Parse before touching the broker context, so a bad config changes nothing.
  var conf: LogosDeliveryConf
  var nodeConf: LogosDeliveryNodeConf
  if h.nodeConf:
    nodeConf = loadNodeConf(h.confJson).valueOr:
      return h.fail("invalid node configuration: " & error)
  else:
    conf = parseLogosDeliveryConf(h.confJson).valueOr:
      return h.fail("invalid node configuration: " & error)

  # `Waku.new` adopts `globalBrokerContext()` as its brokerCtx, and Waku.stop
  # leaves some providers registered (e.g. ServicePeersRequest from
  # node_factory), so a second node on the same context fails with "Provider
  # already set". Every node instance gets a fresh thread broker context; the
  # previous instance's leftover providers stay on its dead context.
  setThreadBrokerContext(NewBrokerContext())

  let ld =
    try:
      (
        if h.nodeConf: await LogosDelivery.new(nodeConf)
        else: await LogosDelivery.new(conf)
      ).valueOr:
        return h.fail("failed to create node: " & error)
    except CatchableError as e:
      return h.fail("failed to create node: " & e.msg)
  for hook in h.afterCreateHooks:
    hook(ld)

  try:
    (await ld.start()).isOkOr:
      discard await ld.stop()
      return h.fail("failed to start node: " & error)
  except CatchableError as e:
    return h.fail("failed to start node: " & e.msg)

  h.ld = ld
  h.startedJson = h.confJson
  h.startedNodeConf = h.nodeConf
  h.startedConf = ld.waku.conf
  for hook in h.attachHooks:
    hook(ld)
  h.setState(NodeState.Running, h.peerIdStr)
  info "node running", peerId = h.peerIdStr
  ok()

proc stop*(h: NodeHost): Future[Result[void, string]] {.async: (raises: []).} =
  if h.ld.isNil:
    h.setState(NodeState.Stopped)
    return ok()
  h.setState(NodeState.Stopping)
  for hook in h.detachHooks:
    await hook()
  let ld = h.ld
  h.ld = nil
  try:
    (await ld.stop()).isOkOr:
      return h.fail("failed to stop node: " & error)
  except CatchableError as e:
    return h.fail("failed to stop node: " & e.msg)
  h.setState(NodeState.Stopped)
  info "node stopped"
  ok()

proc restart*(
    h: NodeHost, confJson = "", nodeConf = false
): Future[Result[void, string]] {.async: (raises: []).} =
  ?(await h.stop())
  await h.start(confJson, nodeConf)

proc installProviders*(h: NodeHost) =
  discard TuiNodeStart.setProvider(
    tuiCtx,
    proc(confJson: string, nodeConf: bool): Future[Result[void, string]] {.async.} =
      (await h.start(confJson, nodeConf)),
  )
  discard TuiNodeStop.setProvider(
    tuiCtx,
    proc(): Future[Result[void, string]] {.async.} =
      (await h.stop()),
  )
  discard TuiNodeRestart.setProvider(
    tuiCtx,
    proc(confJson: string, nodeConf: bool): Future[Result[void, string]] {.async.} =
      (await h.restart(confJson, nodeConf)),
  )
  discard TuiConfigJson.setProvider(
    tuiCtx,
    proc(): Result[HostConf, string] =
      ok(HostConf(json: h.confJson, nodeConf: h.nodeConf)),
  )

{.pop.}
