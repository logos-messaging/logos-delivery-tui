## Admin / node health: connectivity summary, protocol health, connected
## peers as two trees in tabs (by protocol / by peer, short peer ids,
## horizontally scrollable), disconnect / drop all / dial, subscribed topics
## with health. Refreshes every 3 s while the tab is shown; the trees keep
## their expansion and selection across refreshes (TreeView.setRoots).
## Controller: control/health_ctl.nim.

{.push raises: [].}

import std/strutils
import chronos, results
import illview
import ../control/tui_brokers
import ./[common, peer_trees]

type NodeHealthView* = ref object
  app: App
  page*: Window
  summary: Label
  status: Label
  protocols: illview.Table
  peerTabs: TabView
  byProto: TreeView ## protocol > peer > address
  byPeer: TreeView  ## peer > protocols | addresses
  topics: illview.Table
  refreshing: bool

proc refresh*(v: NodeHealthView) {.async: (raises: []).} =
  if v.refreshing:
    return
  v.refreshing = true
  defer:
    v.refreshing = false
  let r = await TuiHealthSnapshot.request(tuiCtx)
  if r.isErr:
    v.summary.setText("— " & r.error)
    v.protocols.setRows(@[])
    v.byProto.setRoots(@[])
    v.byPeer.setRoots(@[])
    v.topics.setRows(@[])
    return
  let s = r.get()
  var uniq: seq[string]
  for p in s.peers:
    if p.peerId notin uniq:
      uniq.add p.peerId
  v.summary.setText(
    "connection: " & s.connectionStatus & "   node health: " & s.nodeHealth &
      "   connected peers: " & $uniq.len & "   subscribed topics: " & $s.topics.len
  )
  var rows: seq[seq[string]]
  for p in s.protocols:
    rows.add @[p.protocol, p.health, p.desc]
  v.protocols.setRows(rows)
  v.byProto.setRoots(byProtocol(s.peers))
  v.byPeer.setRoots(byPeer(s.peers))
  rows = @[]
  for t in s.topics:
    rows.add @[t.shard, t.contentTopic, t.health]
  v.topics.setRows(rows)

proc selectedPeer(v: NodeHealthView): string =
  ## From whichever peer tree is shown: the peer row, or any row under it.
  if v.peerTabs.selected == 0: v.byProto.selectedPeerId(peerDepth = 1)
  else: v.byPeer.selectedPeerId(peerDepth = 0)

proc disconnectSelected(v: NodeHealthView) {.async: (raises: []).} =
  let peer = v.selectedPeer()
  if peer.len == 0:
    v.status.setText("select a peer (or a row under it) in the peer tree")
    return
  let r = await TuiDisconnectPeer.request(tuiCtx, peer)
  v.status.setText(if r.isOk: "disconnected " & short(peer) else: "disconnect failed: " & r.error)
  await v.refresh()

proc dropAll(v: NodeHealthView) {.async: (raises: []).} =
  let yes =
    try:
      await confirm(v.app, "Disconnect ALL peers?")
    except CatchableError:
      false
  if not yes:
    return
  let r = await TuiDisconnectAll.request(tuiCtx)
  v.status.setText(if r.isOk: "all peers disconnected" else: "failed: " & r.error)
  await v.refresh()

proc dial(v: NodeHealthView) {.async: (raises: []).} =
  let maddr =
    try:
      await inputBox(v.app, "Dial peer", "multiaddr (/ip4/../tcp/../p2p/..):")
    except CatchableError:
      none(string)
  if maddr.isNone or maddr.get.strip.len == 0:
    return
  let r = await TuiDialPeer.request(tuiCtx, maddr.get.strip)
  v.status.setText(if r.isOk: "dialed" else: "dial failed: " & r.error)
  await v.refresh()

proc autoRefresh(v: NodeHealthView) {.async: (raises: []).} =
  while v.app.running:
    if v.page.parent != nil and v.page.visible:
      await v.refresh()
    try:
      await sleepAsync(3.seconds)
    except CancelledError:
      return

proc newNodeHealthView*(app: App): NodeHealthView =
  let v = NodeHealthView(app: app)
  v.page = pageWindow("Node health")
  v.summary = newLabel("—").stretchW()
  v.status = newLabel("").stretchW()

  let refreshBtn = newButton("~R~efresh")
  refreshBtn.onClick = proc(b: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      asyncSpawn v.refresh()
  let discBtn = newButton("~D~isconnect peer")
  discBtn.onClick = proc(b: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      asyncSpawn v.disconnectSelected()
  let dropBtn = newButton("Drop ~a~ll peers")
  dropBtn.onClick = proc(b: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      asyncSpawn v.dropAll()
  let dialBtn = newButton("Di~a~l…")
  dialBtn.onClick = proc(b: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      asyncSpawn v.dial()

  v.protocols = newTable(@[
    tableColumn("protocol", prefHint(14)),
    tableColumn("health", prefHint(14)),
    tableColumn("description", prefHint(30, stretch = 1)),
  ])
  proc treePage(title: string, tree: TreeView): Window =
    let w = newWindow(title, rect(0, 0, 0, 0))
    w.closable = false
    tree.dock = dkFill
    w.add tree
    w

  v.byProto = newTreeView()
  v.byPeer = newTreeView()
  v.peerTabs = newTabView()
  v.peerTabs.addPage(treePage("By protocol", v.byProto))
  v.peerTabs.addPage(treePage("By peer", v.byPeer))
  v.topics = newTable(@[
    tableColumn("shard (mesh)", prefHint(26)),
    tableColumn("content topic", prefHint(30, stretch = 1)),
    tableColumn("health", prefHint(20)),
  ])

  let body = newVBox()
  body.dock = dkFill
  body.add row(v.summary)
  body.add row(refreshBtn, discBtn, dropBtn, dialBtn, v.status)
  body.add section("Protocol health", v.protocols, height = 8)
  body.add section(
    "Connected peers   (Shift+←/→ or Shift+wheel: scroll sideways, Ctrl+PgUp/PgDn: tab)",
    v.peerTabs,
  )
  body.add section("Subscribed topics", v.topics, height = 6)
  v.page.add body
  v

proc start*(v: NodeHealthView) =
  asyncSpawn v.autoRefresh()

{.pop.}
