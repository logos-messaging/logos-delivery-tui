## Two-line control bar on a light-gray strip.
##   line 1: network (preset, else cluster id) · mode · layer │
##           peer store (connected) │
##           message counters                              [Log: LEVEL ▾]
##   line 2: [self peer id ▾] ● health          F2 terminal  F3 logs  F9 …
## The peer id button opens a menu of this node's multiaddrs and mounted
## protocols; health is a colour block: green Connected, yellow
## PartiallyConnected, red Disconnected, black when the node is not running.

{.push raises: [].}

import chronos, results
import illview
import ../control/tui_brokers
import ./common

const
  LogLevels = ["TRACE", "DEBUG", "INFO", "NOTICE", "WARN", "ERROR"]
  Hotkeys = [("F2", "terminal"), ("F3", "logs"), ("F4", "filter"), ("F5", "copy"), ("F9", "menu"), ("F10", "quit")]
  BarBg = bgWhite # light gray
  BarFg = fgBlack

type Footer* = ref object
  bar*: ControlBar
  network: Label
  peers: Label
  messages: Label
  levelBtn: Button
  levelMenu: ContextMenu
  peerBtn: Button
  health: Label
  nodeState: NodeState
  nodeInfo: string
  stats: TuiStats

proc onBar[T: View](v: T, fg = BarFg): T =
  v.styleOv.fg = fg
  v.styleOv.bg = BarBg
  v

proc text(s: string, fg = BarFg): Label =
  newLabel(s).onBar(fg)

proc spacer(): Label =
  result = text("")
  result.hint = (prefHint(0, stretch = 1), fixedHint(1))

proc barRow(): BoxLayout =
  result = newHBox()
  result.hint = (prefHint(0, stretch = 1), fixedHint(1))

proc renderHealth(f: Footer) =
  let s = f.stats
  var caption: string
  var fg: ForegroundColor
  var bg: BackgroundColor
  if f.nodeState == NodeState.Running:
    let health = if s.health.len > 0: s.health else: "…"
    case s.connStatus
    of "Connected":
      (fg, bg) = (fgBlack, bgGreen)
    of "PartiallyConnected":
      (fg, bg) = (fgBlack, bgYellow)
    of "Disconnected":
      (fg, bg) = (fgWhite, bgRed)
    else:
      (fg, bg) = (fgBlack, bgYellow) # running, status not reported yet
    caption = " ● " & (if s.connStatus.len > 0: s.connStatus else: "…") & " / " &
      health & " "
  else:
    (fg, bg) = (fgWhite, bgBlack)
    caption =
      if f.nodeState == NodeState.Failed: " ✗ offline: " & f.nodeInfo & " "
      else: " ○ offline (" & $f.nodeState & ") "
  f.health.setText(caption)
  f.health.styleOv.fg = fg
  f.health.styleOv.bg = bg

proc render(f: Footer) =
  let s = f.stats
  var net = if s.network.len > 0: s.network else: "-"
  for part in [s.mode, s.layer]:
    if part.len > 0:
      net.add " · " & part
  f.network.setText(" " & net & " ")
  f.peers.setText(" peers " & $s.peerStore & " (" & $s.peers & " conn) ")
  f.messages.setText(
    " sent " & $s.sent & " · prop " & $s.propagated & " · recv " & $s.received &
      " · relayed " & $s.seen & (if s.errors > 0: " · err " & $s.errors else: "") & " "
  )
  f.peerBtn.applyCaption(if s.peerId.len > 0: short(s.peerId) & " ▾" else: "no peer id")
  f.renderHealth()
  f.levelBtn.applyCaption("Log: " & (if s.logLevel.len > 0: s.logLevel else: "?") & " ▾")
  f.bar.invalidate()

proc setLevel(f: Footer, lvl: string) =
  let r = TuiSetLogLevel.request(tuiCtx, lvl)
  if r.isOk:
    f.stats.logLevel = lvl
  f.render()

proc levelItem(f: Footer, lvl: string): MenuItem =
  # one closure environment per item (a closure built in the loop body
  # would share the loop's environment and always see the last level)
  item(lvl, proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: f.setLevel(lvl))

proc infoItem(label: string): MenuItem =
  item(label, proc() {.gcsafe, raises: [].} = discard) # informational

proc openSelfMenu(f: Footer, b: Button) =
  var items: seq[MenuItem]
  let r = TuiSelfInfo.request(tuiCtx)
  if r.isErr:
    items.add infoItem(r.error)
  else:
    let info = r.get()
    items.add infoItem(info.peerId)
    items.add sep()
    for a in info.addrs:
      items.add infoItem(a)
    if info.addrs.len == 0:
      items.add infoItem("(no announced addresses)")
    items.add sep()
    for p in info.protocols:
      items.add infoItem(p)
  let o = b.absOrigin
  newContextMenu(items).openAt(b, point(o.x, max(o.y - items.len - 2, 0)))

proc newFooter*(): Footer =
  let f = Footer()
  f.bar = newControlBar(lines = 2)
  f.bar.styleOv.fg = BarFg
  f.bar.styleOv.bg = BarBg

  # line 1
  f.network = text("")
  f.peers = text("")
  f.messages = text("")
  var levels: seq[MenuItem]
  for lvl in LogLevels:
    levels.add levelItem(f, lvl)
  f.levelMenu = newContextMenu(levels)
  f.levelBtn = newButton("Log: INFO ▾")
  f.levelBtn.onClick = proc(b: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      let o = b.absOrigin
      f.levelMenu.openAt(b, point(o.x, max(o.y - LogLevels.len - 1, 0)))
  let line1 = barRow()
  line1.add f.network
  line1.add text("│")
  line1.add f.peers
  line1.add text("│")
  line1.add f.messages
  line1.add spacer()
  line1.add f.levelBtn

  # line 2
  f.peerBtn = newButton("no peer id")
  f.peerBtn.onClick = proc(b: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      f.openSelfMenu(b)
  f.health = newLabel("")
  let line2 = barRow()
  line2.add f.peerBtn
  line2.add text(" ")
  line2.add f.health
  line2.add spacer()
  for (key, what) in Hotkeys:
    line2.add text(key, fgRed)
    line2.add text(" " & what & "  ")

  let lines = newVBox()
  lines.hint = (prefHint(40, stretch = 1), fixedHint(2))
  lines.add line1
  lines.add line2
  f.bar.add lines

  discard TuiStats.listen(
    tuiCtx,
    proc(s: TuiStats) {.async: (raises: []).} =
      f.stats = s
      f.render(),
  )
  discard TuiNodeState.listen(
    tuiCtx,
    proc(e: TuiNodeState) {.async: (raises: []).} =
      f.nodeState = e.state
      f.nodeInfo = e.info
      f.render(),
  )
  f.render()
  f

{.pop.}
