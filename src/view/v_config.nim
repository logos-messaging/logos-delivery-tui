## Admin / current configuration: the effective node config (presets merged;
## the running node's when started, else what the editor's JSON gives) as a
## key / value / source table, a
## browser of the network presets beside it, the node config JSON in an
## editor, and node control: start / stop / apply-and-restart, save as / load.
## Double-click (or Enter) on a table row or a preset entry puts that value
## into the JSON, where the config's shape keeps it.
## Controller: control/config_ctl.nim (+ node host providers).

{.push raises: [].}

import std/[json, strutils]
import chronos, results
import illview
import ../app/settings
import ../control/tui_brokers
import ./[common, preset_tree]

type ConfigView* = ref object
  app: App
  page*: Window
  source: Label
  status: Label
  table: illview.Table
  rows: seq[KV] ## what the table shows, row for row
  presets: PresetTree
  presetData: seq[PresetInfo]
  editor: Editor
  editGen: int ## debounces the table rebuild while typing

proc pretty(s: string): string =
  try:
    parseJson(s).pretty() & "\n"
  except CatchableError:
    s

proc refreshPresets(v: ConfigView) =
  ## Marks the preset the editor's JSON names.
  let active = TuiActivePreset.request(tuiCtx, v.editor.text).valueOr("")
  v.presets.setPresets(v.presetData, active)

proc refresh*(v: ConfigView) =
  let r = TuiCurrentConfig.request(tuiCtx, v.editor.text)
  if r.isErr:
    # keep the last good rows; the editor's JSON may be half typed
    v.status.setText("config: " & r.error)
    if v.rows.len == 0:
      v.table.setRows(@[@["(error)", r.error, ""]])
  else:
    v.rows = r.get()
    var rows: seq[seq[string]]
    for kv in v.rows:
      rows.add @[kv.key, kv.value, kv.source]
    v.table.setRows(rows)
  v.refreshPresets()

proc putIntoConfig(v: ConfigView, cfgKey, valueJson: string, append: bool, what: string) =
  let r = TuiPatchConfig.request(tuiCtx, v.editor.text, cfgKey, valueJson, append)
  if r.isErr:
    v.status.setText(what & ": " & r.error)
    return
  v.editor.setText(r.get().json)
  v.status.setText(what & ": " & r.get().message & " — Start / Apply & restart to use it")
  v.refresh()

proc copySelectedRow(v: ConfigView) =
  let i = v.table.selected
  if i < 0 or i >= v.rows.len:
    return
  let kv = v.rows[i]
  if kv.cfgKey.len == 0:
    v.status.setText(kv.key & " is not set from the node config (derived, runtime or hidden)")
    return
  v.putIntoConfig(kv.cfgKey, kv.cfgValue, false, kv.key)

proc loadFromHost*(v: ConfigView) =
  let hc = TuiConfigJson.request(tuiCtx).valueOr(HostConf())
  if hc.nodeConf:
    v.status.setText("the node config is a LogosDeliveryNodeConf: see Admin → Node management")
  else:
    v.editor.setText(pretty(hc.json))
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
  let r = await TuiNodeRestart.request(tuiCtx, text, false)
  v.status.setText(if r.isOk: "node restarted with the edited config" else: "restart failed: " & r.error)
  v.refresh()

proc startStop(v: ConfigView, start: bool) {.async: (raises: []).} =
  # Start uses the editor's config, as Apply & restart does.
  var text = ""
  if start:
    text = v.validJson().valueOr:
      v.status.setText(error)
      return
  v.status.setText(if start: "starting node…" else: "stopping node…")
  let r =
    if start: await TuiNodeStart.request(tuiCtx, text, false)
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
  v.status.setText("loaded " & path & " — Start / Apply & restart to use it")
  v.refresh()

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
    tableColumn("key", prefHint(36)),
    tableColumn("value", prefHint(30, stretch = 1)),
    tableColumn("source", fixedHint(8)),
  ])
  v.table.showScrollbar = true
  # Enter, or a click on the selected row (so: a double click)
  v.table.onActivate = proc(t: illview.Table) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      v.copySelectedRow()
  v.editor = newEditor("")
  v.editor.onChange = proc(e: Editor) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      inc v.editGen
      let gen = v.editGen
      asyncSpawn (proc() {.async: (raises: []).} =
        try:
          await sleepAsync(400.milliseconds)
        except CancelledError:
          return
        if gen == v.editGen:
          v.refresh())()

  v.presets = newPresetTree()
  v.presets.onPick = proc(p: PresetPick) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      v.putIntoConfig(p.cfgKey, p.valueJson, p.append, p.what)
  v.presetData = TuiPresets.request(tuiCtx).valueOr(@[])
  let split = newSplitter(axH, v.table, v.presets)

  let body = newVBox()
  body.dock = dkFill
  body.add row(v.source)
  body.add row(startBtn, stopBtn, applyBtn, saveBtn, loadBtn, resetBtn)
  body.add row(v.status)
  body.add newSplitter(
    axV,
    section(
      "Effective configuration  │  Presets      double-click / Enter: put into the JSON below",
      split,
    ),
    section("Node config JSON (edit, then Apply & restart or Save)", v.editor),
  )
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
