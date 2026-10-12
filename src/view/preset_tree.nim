## Preset browser for the Configuration view: one branch per network preset,
## its fields as leaves, list fields as branches of their items. A double
## click (or Enter on a leaf) reports what to put into the node config:
##   preset name -> "preset": name
##   field       -> that key with the preset's value
##   list        -> the whole list
##   list item   -> appended to the list

{.push raises: [].}

import std/[strutils, tables]
import illview
import ../control/tui_brokers

type
  PresetPick* = object
    cfgKey*: string
    valueJson*: string
    append*: bool
    what*: string ## for messages: "logos.test entry-node #3"

  PresetTree* = ref object of TreeView
    picks: tables.Table[string, PresetPick] ## node key -> what it puts into the config
    onPick*: proc(p: PresetPick) {.gcsafe, raises: [].}

proc pickSelected(t: PresetTree) =
  let n = t.selectedNode
  if n.isNil or t.onPick.isNil:
    return
  t.picks.withValue(n.key, p):
    t.onPick(p[])

method handleEvent*(t: PresetTree, ev: Event): bool {.gcsafe, raises: [].} =
  if ev.kind == evMouse and ev.imouse.action == maPress and ev.clicks == 2:
    result = procCall handleEvent(TreeView(t), ev) # select the row
    t.pickSelected()
    return true
  procCall handleEvent(TreeView(t), ev)

proc jsonStr(s: string): string =
  "\"" & s.multiReplace(("\\", "\\\\"), ("\"", "\\\"")) & "\""

proc newPresetTree*(): PresetTree =
  result = PresetTree()
  initView(result)
  result.focusable = true
  let t = result
  t.onActivate = proc(tv: TreeView) {.gcsafe, raises: [].} =
    t.pickSelected() # Enter on a leaf; Enter on a branch folds it

proc fieldNodes(t: PresetTree, p: PresetInfo, rootKey: string): seq[TreeNode] =
  ## One node per preset field (list fields: a branch of their items),
  ## registering what each puts into the config.
  for f in p.fields:
    let fieldKey = rootKey & "/" & f.label
    if f.isList:
      var items: seq[TreeNode]
      for j, item in f.items:
        let itemKey = fieldKey & "/" & $j
        items.add treeNode(item, key = itemKey)
        t.picks[itemKey] = PresetPick(
          cfgKey: f.cfgKey, valueJson: jsonStr(item), append: true,
          what: p.name & " " & f.label & " #" & $(j + 1),
        )
      result.add treeNode(f.label & " (" & $f.items.len & ")", items, key = fieldKey)
      t.picks[fieldKey] =
        PresetPick(cfgKey: f.cfgKey, valueJson: f.cfgValue, what: p.name & " " & f.label)
    else:
      result.add treeNode(f.label.alignLeft(32) & f.value, key = fieldKey)
      if f.cfgKey.len > 0:
        t.picks[fieldKey] =
          PresetPick(cfgKey: f.cfgKey, valueJson: f.cfgValue, what: p.name & " " & f.label)

proc setPresets*(t: PresetTree, presets: seq[PresetInfo], active: string) =
  ## All presets, one branch each; the active one marked and expanded.
  t.picks.clear()
  var roots: seq[TreeNode]
  for p in presets:
    let isActive = p.name == active
    let rootKey = "p:" & p.name
    t.picks[rootKey] = PresetPick(
      cfgKey: "preset", valueJson: jsonStr(p.name), what: "preset " & p.name
    )
    let root = treeNode(
      (if isActive: "● " else: "  ") & p.name, t.fieldNodes(p, rootKey), key = rootKey
    )
    root.expanded = isActive # new nodes only; the user's choice wins later
    roots.add root
  t.setRoots(roots)

proc setPreset*(t: PresetTree, p: PresetInfo) =
  ## One preset's fields as the roots (Node management's preset pane).
  t.picks.clear()
  t.setRoots(t.fieldNodes(p, "p:" & p.name))

{.pop.}
