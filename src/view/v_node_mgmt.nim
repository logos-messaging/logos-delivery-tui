## Admin / node management: the node config as a `LogosDeliveryNodeConf`
## (control/node_conf.nim). Left: every option, grouped, as a tree table
## (option │ value │ set by │ description); double-click / Enter edits one
## (bools toggle, choices pop a menu, the rest open an input box; empty input
## resets to the default), right-click offers edit / reset. Right: the network
## presets, and the options the selected one sets; double-click / Enter puts a
## value into the JSON. Below: the JSON itself, which the node starts from.
## Buttons as in Current configuration.

{.push raises: [].}

import std/[json, options, strutils, tables, unicode]
import chronos, results
import illview
import ../app/settings
import ../control/tui_brokers
import ./[common, preset_tree]

const
  OptW = 32
  ValW = 24
  SrcW = 8
  HeaderKey = "header"

type
  OptionTree = ref object of TreeView
    onEdit: proc(cli: string, at: Point) {.gcsafe, raises: [].}
    onMenu: proc(cli: string, at: Point) {.gcsafe, raises: [].}

  NodeMgmtView* = ref object
    app: App
    page*: Window
    source: Label
    status: Label
    options: OptionTree
    rows: tables.Table[string, NodeOptionRow] ## by CLI name
    presetList: ListView
    presetNames: seq[string]
    presetTree: PresetTree
    presetData: seq[PresetInfo]
    editor: Editor
    editGen: int ## debounces the tree rebuild while typing

proc optionCli(n: TreeNode): string =
  if n != nil and n.key.startsWith("o:"): n.key[2 .. ^1] else: ""

method handleEvent*(t: OptionTree, ev: Event): bool {.gcsafe, raises: [].} =
  if ev.kind == evMouse and ev.imouse.action == maPress:
    let at = point(ev.imouse.mx + t.absOrigin.x, ev.imouse.my + t.absOrigin.y)
    if ev.imouse.button == mbRight:
      discard procCall handleEvent(TreeView(t), Event(
        kind: evMouse,
        imouse: mouseEvent(maPress, mbLeft, ev.imouse.mx, ev.imouse.my),
      )) # select the row under the mouse
      let cli = t.selectedNode.optionCli
      if cli.len > 0 and t.onMenu != nil:
        t.onMenu(cli, at)
      return true
    if ev.clicks == 2:
      result = procCall handleEvent(TreeView(t), ev)
      let cli = t.selectedNode.optionCli
      if cli.len > 0 and t.onEdit != nil:
        t.onEdit(cli, at)
      return true
  procCall handleEvent(TreeView(t), ev)

proc clip(s: string, w: int): string =
  ## `s` in exactly `w` columns (wide characters count 2), "…" when cut.
  if s.textWidth <= w: s.padWidth(w) else: (s.clipWidth(w - 2) & "…").padWidth(w)

proc rowLabel(r: NodeOptionRow): string =
  r.opt.cli.clip(OptW) & r.value.clip(ValW) & r.source.clip(SrcW) & r.opt.desc

proc pretty(s: string): string =
  try:
    parseJson(s).pretty() & "\n"
  except CatchableError:
    s

# --- presets -------------------------------------------------------------------

proc refreshPresets(v: NodeMgmtView) =
  ## Marks the preset the JSON names; keeps the selection.
  let active = TuiActivePreset.request(tuiCtx, v.editor.text).valueOr("")
  var items: seq[string]
  for p in v.presetData:
    items.add (if p.name == active: "● " else: "  ") & p.name
  v.presetList.setItems(items) # keeps the selection

proc showSelectedPreset(v: NodeMgmtView) =
  let i = v.presetList.selected
  if i >= 0 and i < v.presetData.len:
    v.presetTree.setPreset(v.presetData[i])

# --- options tree --------------------------------------------------------------

proc refresh*(v: NodeMgmtView) =
  let r = TuiNodeOptions.request(tuiCtx, v.editor.text)
  if r.isErr:
    v.status.setText("config: " & r.error) # keep the last good tree
    v.refreshPresets()
    return
  v.rows.clear()
  var groups: seq[string]
  var kids: tables.Table[string, seq[TreeNode]]
  for row in r.get():
    v.rows[row.opt.cli] = row
    if row.opt.group notin groups:
      groups.add row.opt.group
    kids.mgetOrPut(row.opt.group, @[]).add treeNode(row.rowLabel, key = "o:" & row.opt.cli)
  var roots = @[treeNode(
    "option".clip(OptW - 2) & "value".clip(ValW) & "set by".clip(SrcW) & "description",
    key = HeaderKey,
  )]
  for g in groups:
    let n = treeNode(g, kids.getOrDefault(g), key = "g:" & g)
    n.expanded = g == "General"
    roots.add n
  v.options.setRoots(roots)
  v.refreshPresets()

proc apply(v: NodeMgmtView, cli, valueJson: string, append = false, reset = false,
           what = "") =
  let r = TuiNodeConfPatch.request(tuiCtx, v.editor.text, cli, valueJson, append, reset)
  let label = if what.len > 0: what else: cli
  if r.isErr:
    v.status.setText(label & ": " & r.error)
    return
  v.editor.setText(r.get().json)
  v.status.setText(label & ": " & r.get().message & " — Start / Apply & restart to use it")
  v.refresh()

proc choiceItem(v: NodeMgmtView, cli, choice: string): MenuItem =
  # one closure environment per item (a closure built in a loop body shares it)
  item(choice, proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: v.apply(cli, $(%choice)))

proc resetItem(v: NodeMgmtView, cli: string): MenuItem =
  item("Reset to default", proc() {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: v.apply(cli, "", reset = true))

proc textValue(s: string): JsonNode =
  ## Numbers as JSON numbers (the loader takes any scalar as text anyway).
  try:
    %parseBiggestInt(s)
  except ValueError:
    %s

proc editText(v: NodeMgmtView, row: NodeOptionRow) {.async: (raises: []).} =
  let isList = row.opt.kind == NodeOptKind.List
  let initial = if row.opt.secret: "" else: row.value
  let prompt =
    (if row.opt.desc.len > 0: row.opt.desc & "  " else: "") &
      (if isList: "(comma-separated; " else: "(") & "empty = default)"
  let answer =
    try:
      await inputBox(v.app, row.opt.cli, prompt, initial)
    except CatchableError:
      none(string)
  if answer.isNone:
    return
  let s = answer.get.strip
  if s.len == 0:
    v.apply(row.opt.cli, "", reset = true)
  elif isList:
    var items = newJArray()
    for part in s.split(','):
      if part.strip.len > 0:
        items.add part.strip.textValue
    v.apply(row.opt.cli, $items)
  else:
    v.apply(row.opt.cli, $s.textValue)

proc openMenu(v: NodeMgmtView, cli: string, at: Point, withEdit: bool) =
  let row = v.rows.getOrDefault(cli)
  var items: seq[MenuItem]
  if row.opt.kind == NodeOptKind.Choice:
    for c in row.opt.choices:
      items.add v.choiceItem(cli, c)
    items.add sep()
  elif withEdit:
    items.add item("Edit…", proc() {.gcsafe, raises: [].} =
      {.cast(gcsafe).}: asyncSpawn v.editText(row))
  items.add v.resetItem(cli)
  newContextMenu(items).openAt(v.options, at)

proc editOption(v: NodeMgmtView, cli: string, at: Point) =
  if cli notin v.rows:
    return
  let row = v.rows.getOrDefault(cli)
  case row.opt.kind
  of NodeOptKind.Bool:
    v.apply(cli, (if row.value == "true": "false" else: "true"))
  of NodeOptKind.Choice:
    v.openMenu(cli, at, withEdit = false)
  of NodeOptKind.List, NodeOptKind.Text:
    asyncSpawn v.editText(row)

# --- node control ----------------------------------------------------------------

proc setSource*(v: NodeMgmtView, s: string) =
  v.source.setText("source: " & s)

proc showConverted(v: NodeMgmtView, text, origin: string) =
  ## `text` (any node config JSON) into the editor as a LogosDeliveryNodeConf.
  let r = TuiNodeConfFrom.request(tuiCtx, text)
  if r.isErr:
    v.editor.setText(pretty(text))
    v.status.setText(origin & ": " & r.error)
  else:
    v.editor.setText(r.get().json)
    v.status.setText(
      if r.get().message.len > 0: origin & ": " & r.get().message
      elif origin.len > 0: origin
      else: ""
    )
  v.refresh()

proc loadFromHost*(v: NodeMgmtView) =
  let hc = TuiConfigJson.request(tuiCtx).valueOr(HostConf())
  v.showConverted(hc.json, "")

proc validJson(v: NodeMgmtView): Result[string, string] =
  let text = v.editor.text
  try:
    discard parseJson(text)
  except CatchableError as e:
    return err("invalid JSON: " & e.msg)
  ok(text)

proc applyRestart(v: NodeMgmtView) {.async: (raises: []).} =
  let text = v.validJson().valueOr:
    v.status.setText(error)
    return
  v.status.setText("restarting node…")
  let r = await TuiNodeRestart.request(tuiCtx, text, true)
  v.status.setText(if r.isOk: "node restarted with the edited config" else: "restart failed: " & r.error)

proc startStop(v: NodeMgmtView, start: bool) {.async: (raises: []).} =
  var text = ""
  if start:
    text = v.validJson().valueOr:
      v.status.setText(error)
      return
  v.status.setText(if start: "starting node…" else: "stopping node…")
  let r =
    if start: await TuiNodeStart.request(tuiCtx, text, true)
    else: await TuiNodeStop.request(tuiCtx)
  v.status.setText(
    if r.isOk: (if start: "node started" else: "node stopped")
    else: "failed: " & r.error
  )

proc saveAs(v: NodeMgmtView) {.async: (raises: []).} =
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

proc load(v: NodeMgmtView) {.async: (raises: []).} =
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
  v.setSource(path)
  v.showConverted(text, "loaded " & path)

proc newNodeMgmtView*(app: App): NodeMgmtView =
  let v = NodeMgmtView(app: app)
  v.page = pageWindow("Node management")
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

  v.options = OptionTree()
  initView(v.options)
  v.options.focusable = true
  v.options.onEdit = proc(cli: string, at: Point) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: v.editOption(cli, at)
  v.options.onMenu = proc(cli: string, at: Point) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: v.openMenu(cli, at, withEdit = true)
  v.options.onActivate = proc(t: TreeView) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: # Enter on an option row (Enter on a group folds it)
      let o = t.absOrigin
      v.editOption(t.selectedNode.optionCli, point(o.x + 4, o.y + 1))

  v.presetData = TuiPresets.request(tuiCtx).valueOr(@[])
  v.presetList = newListView()
  v.presetList.onSelect = proc(l: ListView) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: v.showSelectedPreset()
  v.presetList.onActivate = proc(l: ListView) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: # double-click / Enter: use this preset
      let i = l.selected
      if i >= 0 and i < v.presetData.len:
        v.apply("preset", $(%v.presetData[i].name), what = "preset " & v.presetData[i].name)
  v.presetTree = newPresetTree()
  v.presetTree.onPick = proc(p: PresetPick) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}: v.apply(p.cfgKey, p.valueJson, p.append, what = p.what)

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

  let presets = newSplitter(
    axH,
    section("Presets", v.presetList),
    section("Options the preset sets   double-click / Enter: into the JSON", v.presetTree),
    pos = 18,
  )
  # The options table gets the room; the preset panes keep a usable width
  # (the divider is clamped against this minimum).
  presets.hint = (SizeHint(min: 42, pref: 42), prefHint(0, stretch = 1))
  let optionsBox = section(
    "Node config (LogosDeliveryNodeConf)   double-click / Enter: edit · right-click: reset",
    v.options,
  )
  # On a narrow screen the options keep their minimum and the presets give.
  optionsBox.hint = (SizeHint(min: 40, pref: 40, stretch: 1), prefHint(3, stretch = 1))
  let top = newSplitter(
    axH, optionsBox, presets,
    pos = 10_000, # clamped: everything but the preset panes' minimum
  )
  let body = newVBox()
  body.dock = dkFill
  body.add row(v.source)
  body.add row(startBtn, stopBtn, applyBtn, saveBtn, loadBtn, resetBtn)
  body.add row(v.status)
  body.add newSplitter(
    axV, top, section("Node config JSON (edit, then Start / Apply & restart or Save)", v.editor)
  )
  v.page.add body
  v.loadFromHost()
  v.showSelectedPreset()
  v

{.pop.}
