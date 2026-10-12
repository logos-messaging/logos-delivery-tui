## Admin / current configuration (view only): the configuration of the
## running node, or of the last one started. The effective config it built
## and runs with, each value with its source (config / preset / default /
## runtime); beside it the preset it applied (hidden when none); below, the
## exact JSON it was started from. Edit and start nodes in Node management.
## Controller: control/config_ctl.nim.

{.push raises: [].}

import std/[json, strutils]
import chronos, results
import illview
import ../control/tui_brokers
import ./[common, preset_tree]

type ConfigView* = ref object
  app: App
  page*: Window
  status: Label
  table: illview.Table
  presets: PresetTree
  presetData: seq[PresetInfo]
  area: Group ## holds `split` (table | preset) or the table alone
  split: Splitter
  presetShown: bool
  jsonBox: GroupBox
  json: TextView

proc showPreset(v: ConfigView, show: bool) =
  ## The preset pane only when a preset was applied; else the table alone.
  if show == v.presetShown:
    return
  v.presetShown = show
  if show:
    v.area.remove(v.table)
    Group(v.split).add(v.table) # the splitter lays out `first`, not child order
    v.area.add(v.split)
  else:
    v.area.remove(v.split)
    Group(v.split).remove(v.table)
    v.area.add(v.table)
  v.area.invalidate()

proc refresh*(v: ConfigView) =
  let sc = TuiStartedConfig.request(tuiCtx).valueOr(StartedConfig(error: error))
  if not sc.started:
    v.status.setText("no node has been started yet — start one in Node management")
    v.table.setRows(@[])
    v.json.clear()
    v.showPreset(false)
    return
  v.status.setText(
    (if sc.running: "node running" else: "node stopped — showing the last started node") &
      " · " & (if sc.preset.len > 0: "preset " & sc.preset else: "no preset")
  )
  var rows: seq[seq[string]]
  if sc.error.len > 0:
    rows.add @["(error)", sc.error, ""]
  for kv in sc.rows:
    rows.add @[kv.key, kv.value, kv.source]
  v.table.setRows(rows)

  v.jsonBox.borderTitle = "Started from this " &
    (if sc.nodeConf: "LogosDeliveryNodeConf" else: "LogosDeliveryConf") & " JSON"
  v.json.clear()
  let text =
    try:
      parseJson(sc.json).pretty()
    except CatchableError:
      sc.json
  for line in text.splitLines:
    v.json.addLine(line)
  v.json.follow = false # clear() turned it on; show from the top
  v.json.top = 0

  var found = false
  for p in v.presetData:
    if p.name == sc.preset:
      v.presets.setPreset(p)
      found = true
  v.showPreset(found)

proc newConfigView*(app: App): ConfigView =
  let v = ConfigView(app: app)
  v.page = pageWindow("Configuration")
  v.status = newLabel("").stretchW()

  v.table = newTable(@[
    tableColumn("key", prefHint(36)),
    tableColumn("value", prefHint(30, stretch = 1)),
    tableColumn("source", fixedHint(8)),
  ])
  v.table.showScrollbar = true
  v.table.dock = dkFill
  v.presets = newPresetTree() # no onPick: read only
  v.presetData = TuiPresets.request(tuiCtx).valueOr(@[])
  v.split = newSplitter(axH, v.table, section("Preset in use", v.presets))
  v.split.dock = dkFill
  Group(v.split).remove(v.table) # no preset until a node with one has started
  v.area = newGroup()
  v.area.dock = dkFill
  v.area.add v.table

  v.json = newTextView()
  v.jsonBox = section("Started from this JSON", v.json)

  let body = newVBox()
  body.dock = dkFill
  body.add row(v.status)
  body.add newSplitter(axV, section("Effective configuration", v.area), v.jsonBox)
  v.page.add body
  v.refresh()

  discard TuiNodeState.listen(
    tuiCtx,
    proc(e: TuiNodeState) {.async: (raises: []).} =
      if e.state in {NodeState.Running, NodeState.Stopped}:
        v.refresh(),
  )
  v

{.pop.}
