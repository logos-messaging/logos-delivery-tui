## Log filter dialog (F4): one row per rule — [AND/OR ▾] [field ▾] [key]
## [op ▾] [value] [✕] — a live preview of the expression and of how many
## kept lines it matches, and named saved filters.

{.push raises: [].}

import std/[options, os, strutils]
import chronos, results
import illview
import ../app/settings
import ../control/log_filter
import ./[common, log_pane]

const SavedKind = "logfilters"

type
  FilterDlg = ref object of Window

  DlgState = ref object
    app: App
    pane: LogPane
    dlg: FilterDlg
    rules: seq[Rule]
    rowsBox: BoxLayout
    enabled: Checkbox
    savedBtn: Button
    savedName: string
    expr, count, status: Label

method handleEvent*(d: FilterDlg, ev: Event): bool {.gcsafe, raises: [].} =
  if ev.kind == evKey and ev.ikey.key == Key.Escape:
    d.endModal(cmCancel)
    return true
  procCall Window(d).handleEvent(ev)

proc pick(b: Button, items: seq[MenuItem]) =
  let o = b.absOrigin
  newContextMenu(items).openAt(b, point(o.x, o.y + 1))

proc fixedW[T: View](v: T, w: int): T =
  v.hint = (fixedHint(w), fixedHint(1))
  v

proc refresh(s: DlgState) =
  let f = LogFilter(rules: s.rules, enabled: true)
  # "~" would read as an accelerator mark in a Label: show a look-alike
  s.expr.setText(if s.rules.len == 0: "(no rules: every line shows)"
                 else: f.describe.replace("~", "∼"))
  let (n, total) = s.pane.preview(f)
  s.count.setText("matches " & $n & " of " & $total & " kept lines")
  s.dlg.invalidate()

proc rebuildRows(s: DlgState) {.gcsafe.}

proc rebuildSoon(s: DlgState) =
  ## Rebuild on the next loop turn: the rows are rebuilt from their own
  ## buttons, which must not leave the view tree while their event is
  ## still being routed through it.
  asyncSpawn (proc() {.async: (raises: []).} =
    try:
      await sleepAsync(0.milliseconds)
    except CancelledError:
      return
    s.rebuildRows())()

# Item factories: each closure gets its own environment (a closure built in a
# loop body would share the loop's and see the last value).
proc joinItem(s: DlgState, i: int, j: Join): MenuItem =
  item($j, proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      s.rules[i].join = j
      s.rebuildSoon())

proc fieldItem(s: DlgState, i: int, f: LogField): MenuItem =
  item((if f == lfKey: "key: (any property)" else: $f), proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      s.rules[i].field = f
      if f == lfLevel:
        s.rules[i].op = opAtLeast
        if s.rules[i].value.len == 0: s.rules[i].value = "WRN"
      elif s.rules[i].op in {opAtLeast, opAtMost}:
        s.rules[i].op = opContains
      s.rebuildSoon())

proc opItem(s: DlgState, i: int, op: LogOp): MenuItem =
  item($op, proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      s.rules[i].op = op
      s.rebuildSoon())

proc buildRow(s: DlgState, i: int): BoxLayout =
  let r = s.rules[i]
  let b = newHBox(spacing = 1)
  b.hint = (prefHint(0, stretch = 1), fixedHint(1))
  if i == 0:
    b.add label("where", 9)
  else:
    let jb = newButton($r.join & " ▾").fixedW(9)
    jb.onClick = proc(x: Button) {.gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        x.pick(@[s.joinItem(i, jAnd), s.joinItem(i, jOr)])
    b.add jb
  let fb = newButton((if r.field == lfKey: "key:" else: $r.field) & " ▾").fixedW(11)
  fb.onClick = proc(x: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      var items: seq[MenuItem]
      for f in LogField:
        items.add s.fieldItem(i, f)
      x.pick(items)
  b.add fb
  let keyIn = newInput(r.key).fixedW(14)
  keyIn.visible = r.field == lfKey
  keyIn.onChange = proc(x: Input) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      s.rules[i].key = x.text
      s.refresh()
  b.add keyIn
  let ob = newButton($r.op & " ▾").fixedW(15)
  ob.onClick = proc(x: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      var items: seq[MenuItem]
      for op in LogOp:
        if s.rules[i].field == lfLevel or op notin {opAtLeast, opAtMost}:
          items.add s.opItem(i, op)
      x.pick(items)
  b.add ob
  let valIn = newInput(r.value).stretchW()
  valIn.onChange = proc(x: Input) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      s.rules[i].value = x.text
      s.refresh()
  b.add valIn
  let del = newButton("✕").fixedW(6)
  del.onClick = proc(x: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      s.rules.delete(i)
      s.rebuildSoon()
  b.add del
  b

proc rebuildRows(s: DlgState) =
  while s.rowsBox.children.len > 0: # not a for loop: removing shrinks the seq
    s.rowsBox.remove(s.rowsBox.children[^1])
  for i in 0 ..< s.rules.len:
    s.rowsBox.add s.buildRow(i)
  let add = newButton("+ Add rule")
  add.onClick = proc(x: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      s.rules.add Rule(join: jAnd, field: lfMsg, op: opContains)
      s.rebuildSoon()
  let clear = newButton("Clear")
  clear.onClick = proc(x: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      s.rules.setLen(0)
      s.rebuildSoon()
  s.rowsBox.add row(add, clear)
  s.refresh()

# --- saved filters -------------------------------------------------------------

proc showSaved(s: DlgState) =
  s.savedBtn.applyCaption("Saved: " & (if s.savedName.len > 0: s.savedName else: "—") & " ▾")
  s.dlg.invalidate()

proc loadItem(s: DlgState, path: string): MenuItem =
  let name = path.splitFile.name
  item(name, proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      let f = loadText(path).flatMap(fromJson)
      if f.isErr:
        s.status.setText(f.error)
        return
      s.rules = f.get.rules
      s.savedName = name
      s.status.setText("loaded " & name)
      s.showSaved()
      s.rebuildSoon())

proc saveAs(s: DlgState) {.async: (raises: []).} =
  let answer =
    try:
      await inputBox(s.app, "Save log filter", "name:", s.savedName)
    except CatchableError:
      none(string)
  if answer.isNone:
    return
  let name = answer.get
  if name.len == 0 or name.contains({'/', '\\'}) or name[0] == '.':
    s.status.setText("not a name: " & name)
    return
  let path = resolveSavePath(SavedKind, name)
  if fileExists(path):
    let yes =
      try:
        await confirm(s.app, "Overwrite the saved filter '" & name & "'?")
      except CatchableError:
        false
    if not yes:
      return
  let r = saveText(path, LogFilter(rules: s.rules).toJson)
  if r.isErr:
    s.status.setText(r.error)
    return
  s.savedName = name
  s.status.setText("saved " & path)
  s.showSaved()

proc deleteSavedFilter(s: DlgState) {.async: (raises: []).} =
  if s.savedName.len == 0:
    s.status.setText("load a saved filter first")
    return
  let yes =
    try:
      await confirm(s.app, "Delete the saved filter '" & s.savedName & "'?")
    except CatchableError:
      false
  if not yes:
    return
  let path = resolveSavePath(SavedKind, s.savedName)
  try:
    removeFile(path)
  except CatchableError as e:
    s.status.setText("cannot delete " & path & ": " & e.msg)
    return
  s.status.setText("deleted " & s.savedName)
  s.savedName = ""
  s.showSaved()

# --- the dialog ------------------------------------------------------------------

proc editLogFilter*(app: App, pane: LogPane) {.async: (raises: []).} =
  ## Open the dialog; Apply sets the pane's filter, Esc / Cancel keep it.
  let cur = pane.filter
  let w = min(max(app.desktop.contentW - 4, 40), 100)
  let h = min(max(app.desktop.contentH - 2, 12), 24)
  let dlg = FilterDlg(borderTitle: "Log filter", closable: false, zoomable: false)
  initView(dlg)
  dlg.border = bkSingle
  dlg.palette = pGray
  dlg.bounds = rect((app.desktop.contentW - w) div 2, (app.desktop.contentH - h) div 2, w, h)
  let s = DlgState(app: app, pane: pane, dlg: dlg, rules: cur.rules)

  s.savedBtn = newButton("Saved: — ▾")
  s.savedBtn.onClick = proc(x: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      var items: seq[MenuItem]
      for p in listSaved(SavedKind):
        items.add s.loadItem(p)
      if items.len == 0:
        s.status.setText("no saved filters yet (" & savedDir(SavedKind) & ")")
      else:
        x.pick(items)
  let saveBtn = newButton("Save as…")
  saveBtn.onClick = proc(x: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: asyncSpawn s.saveAs()
  let delBtn = newButton("Delete")
  delBtn.onClick = proc(x: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: asyncSpawn s.deleteSavedFilter()
  s.enabled = newCheckbox("Enabled", checked = cur.enabled or cur.rules.len == 0)
  let top = row(s.savedBtn, saveBtn, delBtn, s.enabled)
  top.dock = dkTop

  s.rowsBox = newVBox(spacing = 0)
  s.rowsBox.dock = dkFill

  s.expr = newLabel("").stretchW()
  s.count = newLabel("").stretchW()
  s.status = newLabel("").stretchW()
  let apply = newButton("~A~pply")
  apply.isDefault = true
  apply.onClick = proc(x: Button) {.gcsafe, raises: [].} = x.endModal(cmOk)
  let cancel = newButton("~C~ancel")
  cancel.onClick = proc(x: Button) {.gcsafe, raises: [].} = x.endModal(cmCancel)
  let bottom = newVBox(spacing = 0)
  bottom.dock = dkBottom
  bottom.hint = (prefHint(0, stretch = 1), fixedHint(4))
  bottom.add s.expr
  bottom.add s.count
  bottom.add s.status
  bottom.add row(apply, cancel)

  dlg.add top
  dlg.add bottom
  dlg.add s.rowsBox
  s.rebuildRows() # not yet shown: direct

  let cmd =
    try:
      await app.execView(dlg)
    except CatchableError:
      cmCancel
  if cmd == cmOk:
    pane.setFilter(LogFilter(rules: s.rules, enabled: s.enabled.checked))

{.pop.}
