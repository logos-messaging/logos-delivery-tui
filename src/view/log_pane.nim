## The node log pane: every captured line goes into a ring; the pane shows the
## lines the active filter passes. Filtering is the pane's only: the terminal
## mode replay and the real output are untouched.

{.push raises: [].}

import std/[deques, strutils]
import illview
import illview/backend/ansitext
import ../control/log_filter

const BaseTitle = "Node log (F3 hide, F2 full terminal, F4 filter)"

type LogPane* = ref object
  view*: TextView
  raw: Deque[string] ## every line, oldest first, at most `maxLines`
  maxLines: int
  filter: LogFilter
  verdicts: LineVerdicts
  splitter: LineSplitter

proc updateTitle(p: LogPane) =
  p.view.borderTitle =
    if p.filter.active:
      "Node log: " & p.filter.describe.replace("~", "∼") & " — " & $p.view.lines.len & "/" &
        $p.raw.len & " (F4 filter, Shift+F4 off)"
    elif p.filter.rules.len > 0:
      "Node log: filter off — Shift+F4 on (F3 hide, F4 filter)"
    else:
      BaseTitle
  p.view.invalidate()

proc addLine*(p: LogPane, line: string) =
  p.raw.addLast line
  if p.raw.len > p.maxLines:
    discard p.raw.popFirst()
  if p.verdicts.pass(p.filter, line):
    p.view.addLine(line)
  if p.filter.active:
    p.updateTitle() # the counts

proc rebuild(p: LogPane) =
  p.view.clear()
  p.verdicts = LineVerdicts()
  for l in p.raw:
    if p.verdicts.pass(p.filter, l):
      p.view.addLine(l)
  p.updateTitle()

proc filter*(p: LogPane): LogFilter =
  p.filter

proc setFilter*(p: LogPane, f: LogFilter) =
  p.filter = f
  p.rebuild()

proc toggleFilter*(p: LogPane) =
  ## Shift+F4: switch the filter off / on, keeping its rules.
  if p.filter.rules.len > 0:
    p.filter.enabled = not p.filter.enabled
    p.rebuild()

proc preview*(p: LogPane, f: LogFilter): (int, int) =
  ## (lines `f` would show, lines kept) for the filter dialog.
  (f.countMatches(p.raw), p.raw.len)

proc newLogPane*(app: App, maxLines = 5000): LogPane =
  let p = LogPane(view: newTextView(maxLines = maxLines), maxLines: maxLines)
  p.view.borderTitle = BaseTitle
  app.onCapturedOutput = proc(chunk: string) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      for line in p.splitter.feed(stripAnsi(chunk)):
        p.addLine(line)
  p

{.pop.}
