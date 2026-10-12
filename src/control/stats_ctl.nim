## Footer statistics: message counters from logos-delivery events, plus a 2 s
## poll for peer count, gossipsub mesh per subscribed shard, health and
## connection status. Publishes `TuiStats` on `tuiCtx` once a second.

{.push raises: [].}

import std/[json, strutils]
import chronos, chronicles, results
import logos_delivery
import logos_delivery/waku/node/waku_node
import logos_delivery/waku/node/health_monitor/node_health_monitor
import logos_delivery/waku/waku_relay/protocol as relay_protocol
import logos_delivery/waku/api/[peer_manager, relay as relay_api]
import logos_delivery/api/conf/logos_delivery_conf_json
import tools/confutils/cli_args
import logos_delivery/api/conf/modes
import libp2p/[peerinfo, multiaddress]
import logos_delivery/waku/api/events/health_events
import ../app/node_host
import ./[tui_brokers, log_ctl, node_conf]

logScope:
  topics = "ldtui stats"

type StatsCtl = ref object
  stats: TuiStats
  ld: LogosDelivery
  ctx: BrokerContext
  sentL: MessageSentEventListener
  propL: MessagePropagatedEventListener
  recvL: MessageReceivedEventListener
  seenL: MessageSeenEventListener
  errL: MessageErrorEventListener
  connL: EventConnectionStatusChangeListener
  ticker: Future[void]

var gStats {.threadvar.}: StatsCtl

proc snapshot*(): TuiStats =
  ## Current counters (also used by scenario `expect`).
  if gStats.isNil: TuiStats() else: gStats.stats

proc poll(c: StatsCtl) {.async: (raises: []).} =
  let ld = c.ld
  if ld.isNil:
    return
  try:
    let peers = (await ld.waku.connectedPeers()).valueOr(@[])
    c.stats.peers = peers.len
    c.stats.peerStore = (await ld.waku.peerIdsFromPeerstore()).valueOr(@[]).len
    var mesh: seq[MeshEntry]
    if not ld.waku.node.wakuRelay.isNil:
      for shard in ld.waku.node.wakuRelay.subscribedTopics():
        let n = (await ld.waku.relayNumPeersInMesh(shard)).valueOr(-1)
        mesh.add MeshEntry(shard: shard, peers: n)
    c.stats.mesh = mesh
    if not ld.waku.healthMonitor.isNil:
      let report = await ld.waku.healthMonitor.getNodeHealthReport()
      c.stats.health = $report.nodeHealth
      c.stats.connStatus = $report.connectionStatus
  except CatchableError as e:
    debug "stats poll failed", error = e.msg

proc tick(c: StatsCtl) {.async: (raises: []).} =
  var n = 0
  while true:
    if n mod 2 == 0:
      await c.poll()
    inc n
    c.stats.logLevel = currentLogLevel()
    c.stats.peerId = host().peerIdStr
    TuiStats.emit(tuiCtx, c.stats)
    try:
      await sleepAsync(1.seconds)
    except CancelledError:
      return

proc layerOf(ld: LogosDelivery): EntryLayer =
  ## What is actually mounted, whatever the config said.
  if not ld.reliableChannelManager.isNil: EntryLayer.channels
  elif not ld.messagingClient.isNil: EntryLayer.messaging
  else: EntryLayer.kernel

proc describeNode(c: StatsCtl, ld: LogosDelivery) =
  ## network: the preset from the config the node was built from (either
  ## kind: LogosDeliveryNodeConf or LogosDeliveryConf), else the cluster id.
  ## mode: Core / Edge from that config; the kernel layer has none.
  let h = host()
  let layer = ld.layerOf
  var preset = ""
  var mode = LogosDeliveryMode.Core
  if h.nodeConf:
    let conf = loadNodeConf(h.confJson)
    if conf.isOk:
      preset = conf.get().kernel.preset
      mode = conf.get().mode.get(LogosDeliveryMode.Core)
  else:
    let conf = parseLogosDeliveryConf(h.confJson)
    if conf.isOk:
      preset = WakuNodeConf(conf.get().kernelConf).preset
    try: # mode is consumed by the parser; read it from the JSON
      let m = parseJson(h.confJson){"mode"}
      if not m.isNil and m.kind == JString and m.getStr.strip.toLowerAscii == "edge":
        mode = LogosDeliveryMode.Edge
    except CatchableError:
      discard
  c.stats.network =
    if preset.len > 0: preset else: "cluster " & $ld.waku.conf.clusterId
  c.stats.mode = if layer == EntryLayer.kernel: "" else: $mode
  c.stats.layer = $layer

proc selfInfo(c: StatsCtl): Result[SelfInfo, string] =
  if c.ld.isNil or c.ld.waku.node.isNil:
    return err("node is not running")
  let pi = c.ld.waku.node.peerInfo
  var info = SelfInfo(peerId: host().peerIdStr, protocols: pi.protocols)
  for a in pi.addrs:
    info.addrs.add $a
  ok(info)

proc attach(c: StatsCtl, ld: LogosDelivery) =
  c.ld = ld
  c.ctx = ld.waku.brokerCtx
  c.stats.peerId = host().peerIdStr
  c.describeNode(ld)
  c.sentL = MessageSentEvent.listen(
    c.ctx,
    proc(e: MessageSentEvent) {.async: (raises: []).} =
      inc(c.stats.sent),
  ).valueOr(MessageSentEventListener())
  c.propL = MessagePropagatedEvent.listen(
    c.ctx,
    proc(e: MessagePropagatedEvent) {.async: (raises: []).} =
      inc(c.stats.propagated),
  ).valueOr(MessagePropagatedEventListener())
  c.recvL = MessageReceivedEvent.listen(
    c.ctx,
    proc(e: MessageReceivedEvent) {.async: (raises: []).} =
      inc(c.stats.received),
  ).valueOr(MessageReceivedEventListener())
  c.seenL = MessageSeenEvent.listen(
    c.ctx,
    proc(e: MessageSeenEvent) {.async: (raises: []).} =
      inc(c.stats.seen),
  ).valueOr(MessageSeenEventListener())
  c.errL = MessageErrorEvent.listen(
    c.ctx,
    proc(e: MessageErrorEvent) {.async: (raises: []).} =
      inc(c.stats.errors),
  ).valueOr(MessageErrorEventListener())
  c.connL = EventConnectionStatusChange.listen(
    c.ctx,
    proc(e: EventConnectionStatusChange) {.async: (raises: []).} =
      c.stats.connStatus = $e.connectionStatus,
  ).valueOr(EventConnectionStatusChangeListener())

proc detach(c: StatsCtl) {.async: (raises: []).} =
  if c.ld.isNil:
    return
  await MessageSentEvent.dropListener(c.ctx, c.sentL)
  await MessagePropagatedEvent.dropListener(c.ctx, c.propL)
  await MessageReceivedEvent.dropListener(c.ctx, c.recvL)
  await MessageSeenEvent.dropListener(c.ctx, c.seenL)
  await MessageErrorEvent.dropListener(c.ctx, c.errL)
  await EventConnectionStatusChange.dropListener(c.ctx, c.connL)
  c.ld = nil
  c.stats.peers = 0
  c.stats.peerStore = 0
  c.stats.mesh = @[]
  c.stats.health = ""
  c.stats.connStatus = ""

proc resetCounters*() =
  if not gStats.isNil:
    gStats.stats.sent = 0
    gStats.stats.propagated = 0
    gStats.stats.received = 0
    gStats.stats.seen = 0
    gStats.stats.errors = 0

proc init*() =
  let c = StatsCtl()
  gStats = c
  host().onAttach(
    proc(ld: LogosDelivery) {.gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        c.attach(ld)
  )
  host().onDetach(
    proc() {.async: (raises: []).} =
      {.cast(gcsafe).}:
        await c.detach()
  )
  discard TuiSelfInfo.setProvider(
    tuiCtx,
    proc(): Result[SelfInfo, string] =
      c.selfInfo(),
  )
  c.ticker = c.tick()

proc shutdown*() {.async: (raises: []).} =
  if not gStats.isNil and not gStats.ticker.isNil:
    await gStats.ticker.cancelAndWait()

{.pop.}
