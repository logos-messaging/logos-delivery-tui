## TUI shell: sidebar tree | tab group, optional bottom log pane, two-line
## footer. F2 terminal mode (Enter returns), F3 log pane, F9 sidebar, F10 quit.
## Views talk to the control layer only through the app brokers.

{.push raises: [].}

import std/tables
from std/posix import nil # qualified: write/signal clash with chronos
import chronos, chronicles, results
import illview
import ../app/cli
import ../control/tui_brokers
import ./[footer, sidebar, theme, v_messaging, v_node_health, v_config, v_scenario,
  v_placeholder]

logScope:
  topics = "ldtui shell"

type Shell = ref object
  app: App
  main: Group
  tabs: TabView
  side: Sidebar
  logPane: TextView
  footer: Footer
  pages: tables.Table[string, Window]
  health: NodeHealthView
  config: ConfigView
  scenario: ScenarioView

proc openView(sh: Shell, name: string) =
  let w = sh.pages.getOrDefault(name)
  if w.isNil:
    return
  if w.parent != sh.tabs:
    sh.tabs.addPage(w)
  let i = sh.tabs.pages.find(View(w))
  if i >= 0:
    sh.tabs.select(i)
  focusInto(sh.app.desktop, w)
  if name == VConfig:
    sh.config.refresh()
  elif name == VHealth:
    asyncSpawn sh.health.refresh()
  sh.app.requestRedraw()

proc toggleLogPane(sh: Shell) =
  sh.logPane.visible = not sh.logPane.visible
  if not sh.logPane.visible and sh.logPane.isFocused:
    focusInto(sh.app.desktop, sh.tabs)
  sh.app.desktop.invalidate()

proc toggleSidebar(sh: Shell) =
  let t = sh.side.tree
  t.visible = not t.visible
  if t.visible:
    setFocus(sh.app.desktop, t)
  elif t.isFocused:
    focusInto(sh.app.desktop, sh.tabs)
  sh.main.invalidate()

proc terminalMode(app: App) {.async: (raises: []).} =
  ## Leave the TUI; captured output is replayed into the scrollback and then
  ## streams live. Enter (read from a private tty fd) brings the TUI back.
  try:
    app.disableTui()
  except CatchableError as e:
    warn "cannot leave the TUI", error = e.msg
    return
  try:
    stderr.write "\n-- logos-delivery-tui: terminal mode, node logs stream here. " &
      "Press Enter to return --\n"
  except IOError:
    discard
  var fd: cint = -1
  let name = posix.ttyname(cint(0))
  if name != nil:
    fd = posix.open(name, posix.O_RDONLY or posix.O_NONBLOCK)
  try:
    if fd < 0:
      await sleepAsync(2.seconds)
    else:
      var buf: array[64, byte]
      var resume = false
      while not resume and app.running:
        await sleepAsync(100.milliseconds)
        while true:
          let n = posix.read(fd, addr buf[0], buf.len)
          if n <= 0:
            break
          for i in 0 ..< n:
            if char(buf[i]) in {'\n', '\r'}:
              resume = true
  except CancelledError:
    discard
  if fd >= 0:
    discard posix.close(fd)
  if app.running:
    try:
      app.enableTui()
    except CatchableError as e:
      error "cannot re-enter the TUI", error = e.msg
      app.stop()

proc build(sh: Shell) =
  let app = sh.app
  sh.footer = newFooter()
  app.desktop.add sh.footer.bar

  sh.logPane = newTextView(maxLines = 5000)
  sh.logPane.dock = dkBottom
  sh.logPane.border = bkSingle
  sh.logPane.borderTitle = "Node log (F3 hide, F2 full terminal)"
  sh.logPane.hint = (prefHint(0, stretch = 1), fixedHint(12))
  sh.logPane.visible = false
  app.desktop.add sh.logPane
  app.captureTo(sh.logPane)

  sh.main = newGroup()
  sh.main.dock = dkFill
  sh.side = newSidebar()
  sh.side.onOpen = proc(name: string) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      sh.openView(name)
  sh.main.add sh.side.tree
  sh.tabs = newTabView()
  sh.tabs.dock = dkFill
  sh.main.add sh.tabs
  app.desktop.add sh.main

  # Views are built once and only added to / removed from the TabView.
  let msg = newMessagingView()
  sh.health = newNodeHealthView(app)
  sh.config = newConfigView(app)
  sh.scenario = newScenarioView(app)
  sh.pages[VMessaging] = msg.page
  sh.pages[VHealth] = sh.health.page
  sh.pages[VConfig] = sh.config.page
  sh.pages[VScenario] = sh.scenario.page
  for name in [VChannels, VKernel, VPeers]:
    sh.pages[name] = newPlaceholderView(name)

  app.onInput = proc(ev: InputEvent) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      if ev.kind != ikKey or not app.tuiActive:
        return
      case ev.key
      of Key.F2:
        asyncSpawn terminalMode(app)
      of Key.F3:
        sh.toggleLogPane()
      of Key.F9:
        sh.toggleSidebar()
      of Key.F10:
        app.stop()
      else:
        discard

proc runTui*(c: CliConf): Future[int] {.async: (raises: []).} =
  let app = newApp(theme = ldtuiTheme(), captureOutput = true)
  let sh = Shell(app: app)
  sh.build()
  sh.health.start()

  if c.nodeConf.len > 0:
    sh.config.setSource(c.nodeConf)
  if c.scenario.len > 0:
    sh.scenario.loadFile(c.scenario)

  if c.nodeConf.len > 0 and c.autostart:
    sh.openView(VMessaging)
    asyncSpawn (proc() {.async: (raises: []).} =
      let r = await TuiNodeStart.request(tuiCtx)
      if r.isErr:
        sh.openView(VConfig))()
  else:
    sh.openView(VConfig)
  if c.scenario.len > 0:
    sh.openView(VScenario)
  setFocus(app.desktop, sh.side.tree)

  try:
    await app.run()
  except CatchableError as e:
    error "TUI failed", error = e.msg
  # back on the terminal: shut down cleanly, logs visible
  discard await TuiStopScenario.request(tuiCtx)
  let r = await TuiNodeStop.request(tuiCtx)
  if r.isErr:
    return 1
  0

{.pop.}
