## Two-line control bar.
##   line 1: msg sent / propagated / received / relayed, peer count, mesh
##   line 2: hotkeys │ self peer id (short) │ node health / connection
##   right:  log level selector (button + popup menu)

{.push raises: [].}

import std/strutils
import chronos, results
import illview
import ../control/tui_brokers
import ./common

const LogLevels = ["TRACE", "DEBUG", "INFO", "NOTICE", "WARN", "ERROR"]

type Footer* = ref object
  bar*: ControlBar
  line1: Label
  line2: Label
  levelBtn: Button
  levelMenu: ContextMenu
  nodeState: NodeState
  nodeInfo: string
  stats: TuiStats

proc meshText(s: TuiStats): string =
  if s.mesh.len == 0:
    return "n/a"
  var parts: seq[string]
  for m in s.mesh:
    parts.add m.shard.split('/')[^1] & ":" & (if m.peers < 0: "-" else: $m.peers)
  parts.join(" ")

proc render(f: Footer) =
  let s = f.stats
  f.line1.setText(
    "sent " & $s.sent & " · prop " & $s.propagated & " · recv " & $s.received &
      " · relayed " & $s.seen & (if s.errors > 0: " · err " & $s.errors else: "") &
      " │ peers " & $s.peers & " │ mesh " & meshText(s)
  )
  let health =
    case f.nodeState
    of NodeState.Running:
      "● " & (if s.health.len > 0: s.health else: "…") & " / " &
        (if s.connStatus.len > 0: s.connStatus else: "…")
    of NodeState.Failed:
      "✗ FAILED: " & f.nodeInfo
    else:
      "○ " & $f.nodeState
  let pid = if s.peerId.len > 0: short(s.peerId) else: "-"
  f.line2.setText(
    "F2 terminal  F3 logs  F9 menu  F10 quit │ " & pid & " │ " & health
  )
  f.levelBtn.applyCaption("Log: " & (if s.logLevel.len > 0: s.logLevel else: "?") & " ▾")
  f.bar.invalidate()

proc setLevel(f: Footer, lvl: string) =
  let r = TuiSetLogLevel.request(tuiCtx, lvl)
  if r.isOk:
    f.stats.logLevel = lvl
  f.render()

proc newFooter*(): Footer =
  let f = Footer()
  f.bar = newControlBar(lines = 2)
  let lines = newVBox()
  lines.hint = (prefHint(40, stretch = 1), fixedHint(2))
  f.line1 = newLabel("")
  f.line1.hint = (prefHint(40, stretch = 1), fixedHint(1))
  f.line2 = newLabel("")
  f.line2.hint = (prefHint(40, stretch = 1), fixedHint(1))
  lines.add f.line1
  lines.add f.line2
  f.bar.add lines

  proc levelItem(f: Footer, lvl: string): MenuItem =
    # one closure environment per item (a closure built in the loop body
    # would share the loop's environment and always see the last level)
    item(lvl, proc() {.gcsafe, raises: [].} =
      {.cast(gcsafe).}: f.setLevel(lvl))

  var items: seq[MenuItem]
  for lvl in LogLevels:
    items.add levelItem(f, lvl)
  f.levelMenu = newContextMenu(items)
  f.levelBtn = newButton("Log: INFO ▾")
  f.levelBtn.onClick = proc(b: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      let o = b.absOrigin
      f.levelMenu.openAt(b, point(o.x, max(o.y - LogLevels.len - 1, 0)))
  f.bar.addRight f.levelBtn

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
