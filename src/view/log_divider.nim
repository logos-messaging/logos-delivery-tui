## The draggable 1-row divider above the log pane: drag it with the mouse, or
## focus it (Tab) and press Alt+Up / Alt+Down. It sets the pane's height, so
## the pane keeps its size when the terminal is resized (illview's Splitter
## would give every resize to the second pane and ignores `visible`).

{.push raises: [].}

import illview

const
  MinRows = 3 ## log pane content rows
  MinMain = 6 ## rows left above the divider for the main area

type LogDivider* = ref object of View
  pane: View
  dragging: bool

proc setRows(d: LogDivider, rows: int) =
  ## Pane content height, clamped to what its parent can give.
  let p = d.pane
  let chrome = p.bounds.h - p.contentH # the border rows
  let bottom = p.bounds.y + p.bounds.h
  let most = max(bottom - 1 - MinMain - chrome, MinRows)
  let r = clamp(rows, MinRows, most)
  if r != p.contentH:
    p.hint = (p.hint.w, fixedHint(r))
    d.invalidate()

const Grip = " ═══ ⇕ drag · Alt+↑↓ ═══ "

method draw*(d: LogDivider, dc: DrawContext) {.gcsafe, raises: [].} =
  ## A border-like line with a grip in the middle, so it reads as a handle and
  ## not as one more border.
  let line = d.styleOf(tkBorder)
  let grip = d.styleOf(if d.isFocused: tkSelectionFocused else: tkButton)
  let w = max(d.bounds.w, 1)
  for x in 0 ..< w:
    dc.write(x, 0, "─", line)
  let gw = textWidth(Grip)
  if gw <= w:
    dc.write((w - gw) div 2, 0, Grip, grip)

method handleEvent*(d: LogDivider, ev: Event): bool {.gcsafe, raises: [].} =
  case ev.kind
  of evMouse:
    case ev.imouse.action
    of maPress:
      d.dragging = true
      d.captureMouse()
      return true
    of maMove:
      if d.dragging and d.parent != nil:
        # the divider follows the mouse; the pane starts on the row below it
        let y = ev.imouse.my + d.absOrigin.y - d.parent.absOrigin.y
        let p = d.pane
        let chrome = p.bounds.h - p.contentH
        d.setRows(p.bounds.y + p.bounds.h - (y + 1) - chrome)
        return true
    of maRelease:
      if d.dragging:
        d.dragging = false
        d.releaseMouse()
        return true
    else:
      discard
  of evKey:
    if modAlt in ev.ikey.keyMods:
      case ev.ikey.key
      of Key.Up:
        d.setRows(d.pane.contentH + 1)
        return true
      of Key.Down:
        d.setRows(d.pane.contentH - 1)
        return true
      else:
        discard
  of evFocusGained, evFocusLost:
    d.invalidate()
  else:
    discard
  false

proc newLogDivider*(pane: View): LogDivider =
  ## Dock it dkBottom right after the (dkBottom) pane, so it sits above it.
  result = LogDivider(pane: pane)
  initView(result)
  result.focusable = true
  result.dock = dkBottom
  result.hint = (prefHint(0, stretch = 1), fixedHint(1))

{.pop.}
