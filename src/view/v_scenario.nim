## Testing / send scenario: edit, load, save and run scenario files; progress
## of the running scenario. Controller: control/scenario_ctl.nim.

{.push raises: [].}

import std/[json, strutils]
import chronos, results
import illview
import ../app/settings
import ../control/tui_brokers
import ./common

const ExampleScenario* = """{
  "name": "periodic-send",
  "steps": [
    { "action": "waitHealthy", "timeoutS": 60 },
    { "action": "subscribe", "contentTopic": "/logos-delivery-tui/1/chat/proto" },
    { "action": "sendPeriodic", "contentTopic": "/logos-delivery-tui/1/chat/proto",
      "payload": "ping #{seq} from {peerId} at {ts}", "intervalMs": 2000, "count": 10 },
    { "action": "sleep", "ms": 22000 },
    { "action": "expect", "metric": "propagated", "op": ">=", "value": 10, "timeoutS": 30 }
  ]
}
"""

type ScenarioView* = ref object
  app: App
  page*: Window
  path: Input
  status: Label
  editor: Editor
  progress: TextView

proc pretty(s: string): string =
  try:
    parseJson(s).pretty() & "\n"
  except CatchableError:
    s

proc loadFile*(v: ScenarioView, path: string) =
  let text = loadText(path).valueOr:
    v.status.setText(error)
    return
  v.path.setText(path)
  v.editor.setText(pretty(text))
  v.status.setText("loaded " & path)

proc save(v: ScenarioView): Result[string, string] =
  let text = v.editor.text
  try:
    discard parseJson(text)
  except CatchableError as e:
    return err("invalid JSON: " & e.msg)
  let p = v.path.text.strip
  if p.len == 0:
    return err("set a file name or path first")
  let path = resolveSavePath("scenarios", p)
  ?saveText(path, text)
  v.path.setText(path)
  ok(path)

proc run(v: ScenarioView) {.async: (raises: []).} =
  let path = v.save().valueOr:
    v.status.setText(error)
    return
  v.progress.clear()
  let r = await TuiRunScenario.request(tuiCtx, path)
  v.status.setText(if r.isOk: "running " & path else: "cannot run: " & r.error)

proc stop(v: ScenarioView) {.async: (raises: []).} =
  let r = await TuiStopScenario.request(tuiCtx)
  if r.isErr:
    v.status.setText(r.error)

proc newScenarioView*(app: App): ScenarioView =
  let v = ScenarioView(app: app)
  v.page = pageWindow("Scenario")
  v.path = newInput("periodic-send").stretchW()
  v.status = newLabel("").stretchW()
  v.editor = newEditor(ExampleScenario)
  v.progress = newTextView(maxLines = 2000)

  let loadBtn = newButton("~L~oad")
  loadBtn.onClick = proc(b: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      v.loadFile(resolveSavePath("scenarios", v.path.text.strip))
  let saveBtn = newButton("~S~ave")
  saveBtn.onClick = proc(b: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      let r = v.save()
      v.status.setText(if r.isOk: "saved " & r.get() else: r.error)
  let runBtn = newButton("~R~un")
  runBtn.onClick = proc(b: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      asyncSpawn v.run()
  let stopBtn = newButton("St~o~p")
  stopBtn.onClick = proc(b: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      asyncSpawn v.stop()

  let body = newVBox()
  body.dock = dkFill
  body.add row(label("File (name or path)", 20), v.path, loadBtn, saveBtn, runBtn, stopBtn)
  body.add row(v.status)
  body.add section("Scenario JSON (saved under " & savedDir("scenarios") & ")", v.editor, height = 14)
  body.add section("Progress", v.progress)
  v.page.add body

  discard TuiScenarioProgress.listen(
    tuiCtx,
    proc(e: TuiScenarioProgress) {.async: (raises: []).} =
      v.progress.addLine("[" & $e.step & "/" & $e.total & "] " & e.msg)
      if not e.running:
        v.status.setText(e.msg)
      v.progress.invalidate(),
  )
  v

{.pop.}
