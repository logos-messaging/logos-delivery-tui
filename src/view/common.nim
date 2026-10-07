## Small layout helpers shared by the views.

{.push raises: [].}

import illview

proc section*(title: string, child: View, height = 0): GroupBox =
  ## Titled block; `height` > 0 = fixed rows, otherwise it takes the slack.
  let g = newGroupBox(title)
  g.hint = (
    prefHint(0, stretch = 1),
    (if height > 0: fixedHint(height) else: prefHint(3, stretch = 1)),
  )
  child.dock = dkFill
  g.add child
  g

proc row*(views: varargs[View]): BoxLayout =
  ## One-line horizontal strip.
  let b = newHBox(spacing = 1)
  b.hint = (prefHint(0, stretch = 1), fixedHint(1))
  for v in views:
    b.add v
  b

proc label*(text: string, width = 0): Label =
  let l = newLabel(text)
  if width > 0:
    l.hint = (fixedHint(width), fixedHint(1))
  l

proc stretchW*[T: View](v: T): T =
  v.hint = (prefHint(10, stretch = 1), fixedHint(1))
  v

proc pageWindow*(title: string): Window =
  ## A TabView page: closing it from the tab detaches it (kept for reuse).
  let w = newWindow(title, rect(0, 0, 0, 0))
  w.onClose = proc(w: Window) {.gcsafe, raises: [].} =
    if w.parent != nil:
      let p = w.parent
      if p of TabView:
        TabView(p).removePage(w)
      else:
        p.remove(w)
      p.invalidate()
  w

proc short*(id: string, n = 6): string =
  ## "16Uiu2HAm…x9Qa" style shortening.
  if id.len <= 2 * n + 1: id else: id[0 ..< n] & "…" & id[^n .. ^1]

{.pop.}
