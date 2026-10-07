## Admin / current configuration: the resolved config as a k/v table (all
## values stringified), the node config JSON in an editor, and node control:
## start / stop / apply-and-restart, save as / load (XDG dir or any path).
## Controller: control/config_ctl.nim (+ node host providers).

{.push raises: [].}

import std/[json, strutils]
import chronos, results
import illview
import ../app/settings
import ../control/tui_brokers
import ./common

type ConfigView* = ref object
  app: App
  page*: Window
  source: Label
  status: Label
  table: illview.Table
  editor: Editor

proc pretty(s: string): string =
  try:
    parseJson(s).pretty() & "\n"
  except CatchableError:
    s

proc refresh*(v: ConfigView) =
  let r = TuiCurrentConfig.request(tuiCtx)
  if r.isErr:
    v.table.setRows(@[@["(error)", r.error]])
    return
  var rows: seq[seq[string]]
  for kv in r.get():
    rows.add @[kv.key, kv.value]
  v.table.setRows(rows)

proc loadFromHost*(v: ConfigView) =
  let j = TuiConfigJson.request(tuiCtx).valueOr("")
  v.editor.setText(pretty(j))
  v.refresh()

proc setSource*(v: ConfigView, s: string) =
  v.source.setText("source: " & s)

proc validJson(v: ConfigView): Result[string, string] =
  let text = v.editor.text
  try:
    discard parseJson(text)
  except CatchableError as e:
    return err("invalid JSON: " & e.msg)
  ok(text)

proc applyRestart(v: ConfigView) {.async: (raises: []).} =
  let text = v.validJson().valueOr:
    v.status.setText(error)
    return
  v.status.setText("restarting node…")
  let r = await TuiNodeRestart.request(tuiCtx, text)
  v.status.setText(if r.isOk: "node restarted with the edited config" else: "restart failed: " & r.error)
  v.refresh()

proc startStop(v: ConfigView, start: bool) {.async: (raises: []).} =
  v.status.setText(if start: "starting node…" else: "stopping node…")
  let r =
    if start: await TuiNodeStart.request(tuiCtx)
    else: await TuiNodeStop.request(tuiCtx)
  v.status.setText(
    if r.isOk: (if start: "node started" else: "node stopped")
    else: "failed: " & r.error
  )

proc saveAs(v: ConfigView) {.async: (raises: []).} =
  let text = v.validJson().valueOr:
    v.status.setText(error)
    return
  let name =
    try:
      await inputBox(v.app, "Save node config",
        "name (saved under " & savedDir("nodes") & ") or path:")
    except CatchableError:
      none(string)
  if name.isNone or name.get.strip.len == 0:
    return
  let path = resolveSavePath("nodes", name.get.strip)
  let r = saveText(path, text)
  v.status.setText(if r.isOk: "saved " & path else: r.error)

proc load(v: ConfigView) {.async: (raises: []).} =
  let saved = listSaved("nodes")
  let hint = if saved.len > 0: " saved: " & saved.join(", ") else: ""
  let name =
    try:
      await inputBox(v.app, "Load node config", "name or path." & hint)
    except CatchableError:
      none(string)
  if name.isNone or name.get.strip.len == 0:
    return
  let path = resolveSavePath("nodes", name.get.strip)
  let text = loadText(path).valueOr:
    v.status.setText(error)
    return
  v.editor.setText(pretty(text))
  v.setSource(path)
  v.status.setText("loaded " & path & " — Apply to restart the node with it")

proc newConfigView*(app: App): ConfigView =
  let v = ConfigView(app: app)
  v.page = pageWindow("Configuration")
  v.source = newLabel("source: built-in default").stretchW()
  v.status = newLabel("").stretchW()

  proc btn(caption: string, act: proc() {.gcsafe, raises: [].}): Button =
    let b = newButton(caption)
    b.onClick = proc(s: Button) {.gcsafe, raises: [].} =
      act()
    b

  let startBtn = btn("S~t~art node", proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: asyncSpawn v.startStop(true))
  let stopBtn = btn("St~o~p node", proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: asyncSpawn v.startStop(false))
  let applyBtn = btn("~A~pply & restart", proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: asyncSpawn v.applyRestart())
  let saveBtn = btn("~S~ave as…", proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: asyncSpawn v.saveAs())
  let loadBtn = btn("~L~oad…", proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: asyncSpawn v.load())
  let resetBtn = btn("Re~v~ert", proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: v.loadFromHost())

  v.table = newTable(@[
    tableColumn("key", prefHint(40)),
    tableColumn("value", prefHint(40, stretch = 1)),
  ])
  v.table.showScrollbar = true
  v.editor = newEditor("")

  let body = newVBox()
  body.dock = dkFill
  body.add row(v.source)
  body.add row(startBtn, stopBtn, applyBtn, saveBtn, loadBtn, resetBtn)
  body.add row(v.status)
  body.add section("Resolved configuration (kernel / messaging / channels)", v.table)
  body.add section("Node config JSON (edit, then Apply & restart or Save)", v.editor, height = 12)
  v.page.add body
  v.loadFromHost()

  discard TuiNodeState.listen(
    tuiCtx,
    proc(e: TuiNodeState) {.async: (raises: []).} =
      if e.state in {NodeState.Running, NodeState.Stopped}:
        v.refresh(),
  )
  v

{.pop.}
