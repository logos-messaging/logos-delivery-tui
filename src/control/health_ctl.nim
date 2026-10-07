## Node health and peer management: health report, per-protocol peer table,
## subscribed topics with health, and connectivity manipulation (disconnect a
## peer, drop all peers, dial a multiaddr).

{.push raises: [].}

import std/[algorithm, sets, strutils]
import chronos, chronicles, results
import logos_delivery
import logos_delivery/waku/node/waku_node
import logos_delivery/waku/node/health_monitor/node_health_monitor
import logos_delivery/waku/waku_core/codecs
import logos_delivery/waku/api/[peer_manager, subscriptions, relay as relay_api]
import logos_delivery/waku/requests/health_requests
import ../app/node_host
import ./tui_brokers

logScope:
  topics = "ldtui health"

const KnownProtocols* = [
  ("relay", WakuRelayCodec),
  ("store", WakuStoreCodec),
  ("filter", WakuFilterSubscribeCodec),
  ("lightpush", WakuLightPushCodec),
  ("lightpush-legacy", WakuLegacyLightPushCodec),
  ("peer-exchange", WakuPeerExchangeCodec),
  ("metadata", WakuMetadataCodec),
  ("reconciliation", WakuReconciliationCodec),
  ("rendezvous", WakuRendezVousCodec),
]

proc protocolLabel(codec: string): string =
  for (label, c) in KnownProtocols:
    if c == codec:
      return label
  ""

proc running(): Result[LogosDelivery, string] =
  let h = host()
  if not h.isRunning:
    return err("node is not running")
  ok(h.ld)

proc snapshot(): Future[Result[HealthSnapshot, string]] {.async: (raises: []).} =
  let ld = ?running()
  var snap: HealthSnapshot
  try:
    if not ld.waku.healthMonitor.isNil:
      let report = await ld.waku.healthMonitor.getNodeHealthReport()
      snap.nodeHealth = $report.nodeHealth
      snap.connectionStatus = $report.connectionStatus
      for p in report.protocolsHealth:
        snap.protocols.add ProtocolHealthRow(
          protocol: p.protocol, health: $p.health, desc: p.desc.get("")
        )

    let infos = (await ld.waku.connectedPeersInfo()).valueOr:
      return err("cannot list peers: " & error)
    for p in infos:
      var labels: seq[string]
      for codec in p.protocols:
        let l = protocolLabel(codec)
        if l.len > 0 and l notin labels:
          labels.add l
      if labels.len == 0:
        labels.add "other"
      for l in labels:
        snap.peers.add PeerRow(
          protocol: l, peerId: p.peerId, addresses: p.addresses.join(",")
        )
    snap.peers.sort(
      proc(a, b: PeerRow): int =
        result = cmp(a.protocol, b.protocol)
        if result == 0:
          result = cmp(a.peerId, b.peerId)
    )

    var contentTopics: seq[ContentTopic]
    for (shard, topics) in ld.waku.subscribedContentTopics():
      for t in topics:
        contentTopics.add t
    var health: seq[tuple[topic: ContentTopic, health: TopicHealth]]
    if contentTopics.len > 0:
      let r = RequestContentTopicsHealth.request(ld.waku.brokerCtx, contentTopics)
      if r.isOk:
        health = r.get().contentTopicHealth
    for (shard, topics) in ld.waku.subscribedContentTopics():
      var meshTxt = ""
      if not ld.waku.node.wakuRelay.isNil:
        let n = (await ld.waku.relayNumPeersInMesh(shard)).valueOr(-1)
        meshTxt = " (mesh " & $n & ")"
      for t in topics:
        var h = "?"
        for e in health:
          if e.topic == t:
            h = $e.health
        snap.topics.add TopicRow(shard: shard & meshTxt, contentTopic: t, health: h)
  except CatchableError as e:
    return err("health snapshot failed: " & e.msg)
  ok(snap)

proc init*() =
  discard TuiHealthSnapshot.setProvider(
    tuiCtx,
    proc(): Future[Result[HealthSnapshot, string]] {.async.} =
      (await snapshot()),
  )
  discard TuiDisconnectPeer.setProvider(
    tuiCtx,
    proc(peerId: string): Future[Result[void, string]] {.async.} =
      let ld = ?running()
      try:
        discard ?(await ld.waku.disconnectPeerById(peerId))
      except CatchableError as e:
        return err(e.msg)
      notice "disconnected peer", peerId
      ok(),
  )
  discard TuiDisconnectAll.setProvider(
    tuiCtx,
    proc(): Future[Result[void, string]] {.async.} =
      let ld = ?running()
      try:
        discard ?(await ld.waku.disconnectAllPeers())
      except CatchableError as e:
        return err(e.msg)
      notice "disconnected all peers"
      ok(),
  )
  discard TuiDialPeer.setProvider(
    tuiCtx,
    proc(multiaddr: string): Future[Result[void, string]] {.async.} =
      let ld = ?running()
      try:
        discard ?(await ld.waku.connect(@[multiaddr], 10_000))
      except CatchableError as e:
        return err(e.msg)
      notice "dialed peer", multiaddr
      ok(),
  )

{.pop.}
