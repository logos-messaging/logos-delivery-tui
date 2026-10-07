# logos-delivery-tui — Plan & Design

Status: v1 implemented (2026-10-08), with every decision in §12 taken as
recommended. §13 records where the implementation deviated from this plan and
the upstream issues found along the way.

## 1. Goal (condensed)

A native Nim terminal UI around one in-process `LogosDelivery` instance, used for
internal testing locally and against the live fleet. It does the following:

- acts as a message actor: manual send/receive plus configurable automatic sends
- gives insight into health, peers, mesh and topics, and tails the node's logs
- can configure the node visually and save that config for later
- has a headless mode that runs a scenario file in the test harness or on the fleet

## 2. Grounding facts (from the dependency survey)

| Fact | Source | Consequence |
|---|---|---|
| `LogosDelivery = ref object (waku, messagingClient, reliableChannelManager)` | `logos-delivery/logos_delivery/logos_delivery.nim:72` | The model is this object. Peers, health and relay are reached through `ld.waku.*`. |
| JSON config: `parseLogosDeliveryConf(jsonStr): ConfResult[LogosDeliveryConf]` → `LogosDelivery.new(conf)` | `logos_delivery/api/conf/logos_delivery_conf_json.nim:100`, `logos_delivery.nim:168` | `--node-conf` takes the same JSON shape that `logosdelivery_create_node` and the delivery-module (`conf/logos-test.json`) take. |
| `Waku.new` calls `setupLog(...)`, which writes chronicles output to **stdout** | `waku/waku.nim:197` | We capture fd 1/2 with illview (`captureOutput = true`) rather than fighting the sinks. See §7. |
| Runtime log level needs `-d:chronicles_runtime_filtering=on` and chronicles `setLogLevel`. No public logos-delivery helper exists. | `waku/rest_api/endpoint/admin/handlers.nim:436`, `apps/logos_delivery_node/nim.cfg` | We copy the node's nim.cfg defines and call `setLogLevel` directly. |
| logos-delivery requires `--mm:refc --threads:on -d:discv5_protocol_id=d5waku` and `nim == 2.2.6` | `logos_delivery.nimble`, `config.nims` | The TUI is **refc-only**. ORC is not a target. illview also lists ORC churn crashes (deviations #22/#23). |
| Native libs (miniupnpc, libnatpmp, BearSSL, Leopard, tinycbor, librln) are built by the logos-delivery Makefile, not by nimble | `Makefile`, `Nat.mk`, `Leopard.mk`, … | A pure-nimble consumer must reproduce these builds. See **[D1]**. |
| illview has no loop of its own: `app.run()` is `{.async.}` on the chronos loop, and widgets must be touched on the loop thread | `nim-illview/src/illview/core/app.nim:378, :203` | The node and the UI share **one thread and one chronos loop**. See **[D2]**. |
| illview: POSIX only (no Windows input driver); capture needs `threads:on` | `docs/WINDOWS-DRIVER.md`, `docs/OUTPUT-CAPTURE.md` | Supported platforms are macOS and Linux. Windows is out of scope. |
| illview has **no dropdown** widget | survey | The log-level "dropdown" is a button that opens a `ContextMenu`. See **[D5]**. |
| F2/Enter terminal mode is not built in; ex14 shows the pattern | `nim-illview/examples/ex14_logpane.nim:86-118` | We port the ex14 pattern. |
| nim-brokers v3.4.0: logos-delivery pins `fd97eb3`, the v3.4.0 release commit, and illview requires `>= 3.4.0` | nimble files | The versions agree. |
| No "relayed" counter exists; events exist for sent, propagated, received and seen | `api/events/*`, `metrics` | Counter semantics are listed in §8. See **[D6]**. |

## 3. Platform / memory-model matrix

| | macOS | Linux | Windows | Reason |
|---|---|---|---|---|
| `--mm:refc` | ✅ target | ✅ target | ❌ | logos-delivery mandates refc. illview has no Windows input driver. |
| `--mm:orc` | ❌ | ❌ | ❌ | logos-delivery does not build under ORC, and illview has an ORC churn bug. |
| Headless (no illview) | ✅ | ✅ | ⚠️ possible later | Headless mode does not touch illview, so only logos-delivery's Windows support would matter. |

Single thread, single chronos loop. The only extra threads are illview's capture-drain thread and whatever logos-delivery spawns internally. No new cross-thread GC (garbage collector) ownership is introduced: under refc, nothing GC'd crosses threads in our code.

## 4. Repository layout (pure nimble)

```
logos-delivery-tui/
  logos_delivery_tui.nimble     # bin = @["logos_delivery_tui"], srcDir = "src"
  nimble.lock
  config.nims                   # mm:refc, threads:on, chronicles + discv5 defines (copied from node nim.cfg)
  conf/                         # example node confs + scenarios
    logos-test.json
    scenarios/ping-pong.json
  docs/DESIGN.md
  src/
    logos_delivery_tui.nim      # entry: parse CLI → headless | tui
    app/
      cli.nim                   # confutils CLI
      settings.nim              # saved node confs / scenarios (load/save JSON)
      node_host.nim             # owns LogosDelivery: create/start/stop/restart, exposes ctx
    control/                    # nim-brokers based control layer (no illview import!)
      tui_brokers.nim           # app-level EventBroker/RequestBroker declarations
      stats_ctl.nim             # counters, peer count, mesh, health → StatsUpdated
      log_ctl.nim               # log level set/get
      messaging_ctl.nim         # send / subscribe / received-message stream
      peers_ctl.nim             # per-protocol peer tables, disconnect/dial
      health_ctl.nim            # health report, protocol health, subscribed topics
      config_ctl.nim            # current conf as k/v, edit/save
      scenario_ctl.nim          # scenario parser + runner (shared by headless and TUI)
    view/                       # illview only; talks to control via brokers
      shell.nim                 # desktop: sidebar, TabView, log pane, footer, F2 mode
      footer.nim
      sidebar.nim
      v_messaging.nim
      v_node_health.nim
      v_config.nim
      v_scenario.nim
      v_placeholder.nim         # Channels / Kernel messaging / Peers until specified
    headless/
      runner.nim                # no illview import; drives scenario_ctl, prints JSONL report
  tests/
    test_scenario_parse.nim
    test_control_*.nim          # control layer against a real in-process node (no UI)
```

Rule: **`control/` never imports illview, and `view/` never imports logos_delivery**.
That keeps the controllers testable without a terminal and lets headless mode reuse them.
The spec asks for each view to have its controller in a separate source file. The `v_X.nim` and `X_ctl.nim` pairs satisfy that.

## 5. MVC split with nim-brokers

```
 illview widgets ──(UI callbacks)──► RequestBroker (tuiCtx) ──► *_ctl ──► LogosDelivery API
       ▲                                                          │
       └──── EventBroker listeners (tuiCtx) ◄── emit ◄────────────┘◄── logos-delivery EventBrokers
                                                                       (ld.waku.brokerCtx)
```

- **Two broker contexts.**
  - `ld.waku.brokerCtx` belongs to logos-delivery. Only controllers listen there, to events such as `MessageReceivedEvent`, `MessageSentEvent`, `MessagePropagatedEvent`, `MessageErrorEvent`, `MessageSeenEvent`, `WakuPeerEvent`, `EventConnectionStatusChange`, `EventProtocolHealthChange`, `EventContentTopicHealthChange` and `ContentTopicSubscribedEvent`.
  - `tuiCtx = NewBrokerContext()` is ours. Views and the headless runner talk to controllers only on this context.
- **App brokers** (single-thread, non-`(mt)`, async), sketched in `tui_brokers.nim`:
  - `RequestBroker`:
    - `TuiSend(contentTopic, payload: seq[byte], ephemeral): RequestId`
    - `TuiSubscribe(contentTopic)` and `TuiUnsubscribe(contentTopic)`
    - `TuiSetLogLevel(level)`
    - `TuiHealthSnapshot(): HealthView`
    - `TuiPeerTable(): seq[PeerRow]`
    - `TuiCurrentConfig(): seq[(string, string)]`
    - `TuiDisconnectPeer(peerId)` and `TuiDisconnectAll()`
    - `TuiRunScenario(path)` and `TuiStopScenario()`
    - `TuiNodeStart()`, `TuiNodeStop()` and `TuiNodeRestart(confJson)`
  - `EventBroker`:
    - `TuiStats{sent, propagated, received, seen, errors, peers, mesh: seq[(shard, n)], health, connStatus}`, throttled to at most 2 Hz
    - `TuiChatLine{dir, contentTopic, payload, hash, ts, status}`
    - `TuiNodeState{state}`
    - `TuiScenarioProgress{step, total, msg}`
- **Lifetime:** listeners return handles. `node_host` drops all logos-delivery listeners on stop and restart, before `ld.stop()`, so no listener outlives the `Waku` it closed over.
- **Risk to validate in Phase 0:** `newApp()` "takes over the thread's `globalBrokerContext()`", and logos-delivery assigns `waku.brokerCtx`. I need to confirm the two do not collide. The order would be: create `tuiCtx`, create the app, then create the node.

## 6. CLI

```
logos_delivery_tui [--node-conf=<file.json>] [--scenario=<file.json>] [--headless]
                   [--log-level=INFO|DEBUG|TRACE] [--log-file=<path>] [--autostart=true]
```

- `--node-conf` takes the same JSON as `parseLogosDeliveryConf`: layered `{entryLayer, mode, preset, kernelConf, messagingOverrides, channelsOverrides}` or the legacy flat form.
- With no `--node-conf`, the TUI opens the Config view with a default `{"preset":"logos.test"}` and the node not started. See **[D7]**.
- `--headless` requires `--node-conf` and `--scenario`. It exits non-zero if the node fails or a scenario `expect` fails.
- Saved configs and scenarios go to `./conf/`, or to a path chosen in the save dialog. See **[D8]**.

## 7. Logs, log pane, terminal mode

- `newApp(captureOutput = true)` redirects fd 1/2 to a pty, so chronicles' stdout output, from any thread, lands in illview's ring buffer (1 MiB).
- `app.captureTo(logPaneTextView)` feeds the optional bottom log pane, with ANSI codes stripped. F3 (proposed) toggles the pane by setting `visible`, calling `invalidate`, and moving focus away if the pane held it.
- **F2** calls `disableTui()`, which replays the backlog into the real scrollback and then streams logs live, keeping their colours. **Enter** calls `enableTui()`. This is the ex14 pattern.
- `--log-file` additionally tees to a file, for long fleet runs. Chronicles gets a second `textlines` sink. See **[D9]**.
- Headless: no capture, logs go to stdout as normal, and the scenario report is written to stderr or to a file as JSONL.

## 8. TUI layout

```
┌──────────────┬─────────────────────────────────────────────────────────┐
│ ▸ Channels   │ [Messaging ×][Node health ×][Config ×]                   │
│ ▸ Messaging  │                                                          │
│ ▸ Kernel msg │              active tab (dkFill)                         │
│ ▸ Peers      │                                                          │
│ ▾ Admin      │                                                          │
│   Node health│                                                          │
│   Config     │                                                          │
│ ▾ Testing    │                                                          │
│   Scenario   │                                                          │
├──────────────┴─────────────────────────────────────────────────────────┤
│ log pane (optional, F3)                                                 │
├────────────────────────────────────────────────────────────────────────┤
│ sent 12 · prop 12 · recv 30 · seen 210 │ peers 8 │ mesh /waku/2/rs/1/0:6 │ [log: INFO ▾] │
│ F2 terminal  F3 logs  F9 sidebar  F10 quit │ 16U…x9Qa │ ● READY / Connected │
└────────────────────────────────────────────────────────────────────────┘
```

- **Construction:** docking on the desktop. The footer is a `ControlBar(lines=2)` with `dkBottom`; the log pane is a `TextView` with `dkBottom` and a fixed height. The sidebar is a `TreeView` with `dkLeft`, and the main area is a `TabView` with `dkFill`. Docking honours `visible`; `Splitter` does not, which is why it is avoided.
- **Sidebar:** **F9** toggles it, as does a menu entry. Activating a node opens a tab, or focuses it if already open. Each view is built **once** and then added and removed, following illview's ORC churn advice; it is harmless under refc too.
- **Footer counter semantics** (see **[D6]**):

  | Counter | Source |
  |---|---|
  | sent | `MessageSentEvent` |
  | prop(agated) | `MessagePropagatedEvent` |
  | recv | `MessageReceivedEvent` (messaging layer, subscribed content topics) |
  | seen ("relayed") | `MessageSeenEvent` (kernel, all relay traffic on our shards) |
  | errors | `MessageErrorEvent` |

- **Peers and mesh:** `connectedPeers().len`, plus `relayNumPeersInMesh(shard)` for each subscribed shard. An Edge node shows `mesh: n/a (edge)`.
- **Health:** `getConnectionStatus` plus the node health from `healthMonitor.getNodeHealthReport()`. Event-driven updates come from `EventConnectionStatusChange` and `EventProtocolHealthChange`, and a 2 s poll acts as a safety net.
- **Log level:** a button that opens a `ContextMenu` with INFO/DEBUG/TRACE (see **[D5]**). Choosing one calls `TuiSetLogLevel`, which calls chronicles `setLogLevel`.

## 9. Views (v1 scope)

| View | Content | Controller calls |
|---|---|---|
| **Admin / Node health** | Connection status and node health. Protocol health table (protocol, status, desc). Per-protocol peer table (relay / filter / lightpush / store / px), with columns peerId, addrs, protocols and the context action Disconnect. Subscribed topics table (pubsub shard → content topics, topic health). | `getNodeHealthReport`, `peerIdsByProtocol(codec)`, `connectedPeersInfo`, `subscribedContentTopics`, `RequestContentTopicsHealth`, `disconnectPeerById` |
| **Admin / Current config** | A two-column k/v `Table`, values stringified. It flattens the effective `LogosDeliveryConf`, so a `kernel.*`, `messaging.*` or `channels.*` key prefix shows which layer each key came from. Edit, Save as… and "Restart node with this config" actions cover the "visual config + save" requirement. | `TuiCurrentConfig`, `TuiNodeRestart` |
| **Messaging** | A content-topic `Input`, pre-set to the app default `/logos-delivery-tui/1/chat/proto`, with **[Subscribe]** next to it. A payload `Editor` (text) with a `base64` checkbox: when checked, the input is decoded as base64; otherwise UTF-8 bytes are sent. **[Send]**. Below that, a chat `TextView` with one line per send or receive: `hh:mm:ss → /topic  "text"  [sent ✓ / propagated ✓✓ / error ✗]`, with status updated by requestId. | `TuiSend`, `TuiSubscribe`, `TuiChatLine` |
| **Testing / Send scenario** | Load or save a scenario file, view its steps, Run and Stop, and a progress and log list. | `TuiRunScenario`, `TuiScenarioProgress` |
| Channels, Kernel messaging, Peers | A "to be specified" placeholder tab | — |

Payload interpretation: the spec says "binary base64 encoded". The default above sends plain text and offers base64 as an opt-in. See **[D10]**.

## 10. Scenario format (v0, extensible)

```json
{
  "name": "ping-pong",
  "nodeConf": "conf/logos-test.json",
  "startNode": true,
  "steps": [
    { "action": "waitHealthy", "timeoutS": 60 },
    { "action": "subscribe", "contentTopic": "/ldtui/1/ping/proto" },
    { "action": "sendPeriodic", "contentTopic": "/ldtui/1/ping/proto",
      "payload": "ping #{seq} from {peerId}", "intervalMs": 2000, "count": 30, "jitterMs": 200 },
    { "action": "sleep", "ms": 5000 },
    { "action": "disconnectAllPeers" },
    { "action": "sleep", "ms": 10000 },
    { "action": "restartNode" },
    { "action": "expect", "metric": "received", "op": ">=", "value": 25 }
  ]
}
```

- **v0 actions:** `waitHealthy`, `subscribe`, `unsubscribe`, `send`, `sendPeriodic` (runs in the background), `sleep`, `disconnectPeer`, `disconnectAllPeers`, `dialPeer`, `stopNode`, `startNode`, `restartNode`, `setLogLevel`, and `expect` (over the `TuiStats` counters).
- **Placeholders:** `{seq}`, `{peerId}`, `{ts}`, `{rand:N}`.
- **One runner:** headless and TUI use the same `scenario_ctl` runner. Only the progress sink differs: JSONL to stdout or a file in headless mode, the scenario tab in the TUI.
- **"Dropping nodes":** only **this** process's node and its connections can be controlled. Killing other fleet or harness containers is out of scope. See **[D11]**.

## 11. Implementation phases

Each phase ends with a real build plus run.

| # | Phase | Verify |
|---|---|---|
| 0 | **Build spike.** Create the nimble project. Require logos_delivery, brokers v3.4.0 and illview v0.1.0, with config.nims. Get the native libs building (see [D1]). A hello program creates the node from `logos-test.json`, starts it, prints peer count, and runs inside an illview `App` with capture. | `nimble build` works on macOS and Linux. The node reaches Connected on logos.test. The TUI renders and logs appear in the pane. Settle the broker-context interplay. |
| 1 | `node_host`, `tui_brokers`, `stats_ctl`, `log_ctl`, plus shell, footer, sidebar, tabs, log pane, F2/F3/F9 | Manual run against logos.test. Counters move, and changing the log level visibly changes the log volume. |
| 2 | Messaging view and controller | Two TUI instances on localhost (two confs) exchange messages, and both chat panes show sent/propagated/received. |
| 3 | Node health and Config views and controllers, plus config save and restart | Tables populated. Disconnecting a peer is reflected. A saved conf reloads identically. |
| 4 | Scenario parser and runner, headless mode, and Scenario view | `tests/test_scenario_parse.nim`. A headless ping-pong between two local nodes exits 0, and an injected failing `expect` exits non-zero. |
| 5 | Polish and docs | README covering build, run, config and scenario reference. |

Testing: `nimble test` runs the parser unit tests and control-layer tests against a real in-process node, with no UI. The UI is verified manually.
Under refc, the controller tests also run under ASAN (AddressSanitizer). The point is listener and closure lifetimes across node restart.

## 12. Decisions needed

**Resolved (2026-10-07):**
- **D1:** (a) nimble `requires` plus a `buildNativeDeps` task, with a generated
  lock (see §13).
- **D2:** a single thread.
- **D3:** RLN off by default.
- **D6:** event-based counters as in §8.
- **D4, D5, D7–D12:** taken as recommended when implementation was approved.

| # | Question | Options | My recommendation |
|---|---|---|---|
| **D1** | How to consume logos-delivery and its native libs in a "pure nimble" project | (a) `requires "https://github.com/logos-messaging/logos-delivery#master"`, plus a `nimble buildNativeDeps` task that builds nat-traversal, BearSSL, Leopard and tinycbor from the installed package dirs; default `-d:disable_rln`, with an opt-in task for librln. (b) A git submodule `vendor/logos-delivery`, using its Makefile `build-deps`/`librln` and its `nimbledeps` path. (c) An env var `LOGOS_DELIVERY_DIR` pointing at a local checkout. | **(a)**, with (c) as a dev override (`--path`) so you can test against a local branch. How heavy (a) turns out depends on Phase 0. |
| **D2** | Threading | (a) Node and UI on one thread and one chronos loop. (b) Node on a worker thread, with `(mt)` brokers to the UI. | **(a).** It is simpler, refc-safe and matches illview's model. The trade-off: if the loop lags (`EVENT_LOOP_LAGGING`), the UI lags too, which is itself a useful signal. (b) can come later because the broker API is unchanged. |
| **D3** | RLN | Off by default (`-d:disable_rln`) or always on | Off by default, with an `rln` build flavour. Does the logos.test/dev fleet need RLN for publishing? If it does, the default must flip. |
| **D4** | Scope of "Kernel messaging", "Channels" and "Peers" for v1 | Placeholders, or a minimal version now | Placeholders; you said they will be defined later. |
| **D5** | Log-level "dropdown" | (a) A button that opens a ContextMenu. (b) Build a reusable `Dropdown` widget in illview upstream. | **(a)** now. (b) is a later upstream improvement. |
| **D6** | Footer "sent/relayed/received" semantics | As in §8 (`seen` = kernel `MessageSeenEvent` as "relayed"), or use the `logos_delivery_node_messages` metric | Events as in §8, because the metrics don't cover "sent". |
| **D7** | Start-up without `--node-conf` | Open the Config view with the node stopped, or auto-start the `logos.test` preset | Config view, node stopped. |
| **D8** | Where saved configs and scenarios live | `./conf/`, or `~/.config/logos-delivery-tui/` (XDG) | XDG for saved items, and accept any path on the CLI. |
| **D9** | Log persistence | Pane plus terminal mode only, or also `--log-file` | Add `--log-file` (cheap and valuable on the fleet). |
| **D10** | Payload entry | Text by default with an opt-in base64 toggle, or base64-only as the spec literally says | Text default with a base64 toggle. |
| **D11** | Harness integration in v1 | Headless binary only, or also a `logosdeliverytui` kind in the test-harness `gen_compose.py` and image | Binary only in v1. Harness integration is a follow-up in that repo. |
| **D12** | logos-delivery "latest master" | Track `master` HEAD unpinned, or pin in `nimble.lock` and bump deliberately | Pin it in the lock and bump on purpose. Unpinned master breaks reproducibility. |

## 13. Implementation notes and deviations

| Topic | What happened | Where |
|---|---|---|
| Dependency resolution | `nimble setup` cannot solve logos-delivery's graph from the `.nimble` files. libp2p 2.4.1 requires `lsquic >= 0.9.0`, while logos-delivery pins lsquic by commit, and leopard conflicts the same way. logos-delivery itself only builds from its `nimble.lock`. So our `nimble.lock` is generated from logos-delivery's lock at the pinned revision, plus `logos_delivery` and `illview` entries. The checksums use nimble's algorithm, verified against the brokers entry. | `scripts/gen_lock.py` |
| Native libs | `nimble buildNativeDeps` mirrors `Nat.mk`, `BearSSL.mk` and `Leopard.mk` (the leopard cmake test stubs). TinyCBOR is not needed because we don't consume the C bindings. | `logos_delivery_tui.nimble` |
| Broker context per node | `Waku.new` adopts `globalBrokerContext()` (`waku.nim:195`). `Waku.stop` leaves the `ServicePeersRequest` provider registered (`node_factory.nim:190`), so a second node in the process fails with "Provider already set". `node_host.start` therefore installs a fresh `NewBrokerContext()` as the thread context before every `LogosDelivery.new`. The previous instance's leftover providers stay on its dead context and keep their closure environments alive: a small retained leak per restart. **Upstream fix:** clear the provider in `Waku.stop`. | `src/app/node_host.nim` |
| libp2p shutdown race | In libp2p 2.4.1, `AddressManager.resolve` (`address_manager.nim:470`) iterates `self.mappers` across an `await`. `NATService.stop` removes its mapper during `switch.stop()`, which raises an `AssertionDefect` ("the length of the seq changed while iterating"). It only hits when stop lands while a UPnP/NAT-PMP pass is in flight, which is likely on networks without a UPnP gateway. The example configs set `"nat": "none"`. **Upstream fix:** iterate a copy of `mappers`. | `conf/*.json` |
| Log routing | No custom chronicles sink. `setupLog` writes to stdout, and illview's pty capture feeds both the log pane and F2 terminal mode. `--log-file` wraps the active writer after every node create. Compile-time level is TRACE, filtered at runtime. | `src/control/log_ctl.nim` |
| Async providers | Broker async providers must be plain `{.async.}`. The provider type is `Future[T]`, and a `{.async: (raises: []).}` lambda yields an `InternalRaisesFuture` that does not match. | `src/control/*` |
| Loop closures | Closures created in a loop body share one environment in Nim. The log-level menu items initially all set the last level. Each item's closure is now built in a factory proc. | `src/view/footer.nim` |

### Verification (macOS arm64, refc)

| Check | Result |
|---|---|
| `nimble test` (scenario parser, config flatten) | 10/10 OK |
| Headless node on logos.test: start, about 19 peers, Ctrl-C | clean stop, exit 0 |
| `conf/scenarios/ping.json` headless | PASSED, exit 0 |
| Failing `expect` / missing file / bad CLI arg | exit 1 / 2 / 2 |
| `conf/scenarios/connectivity.json`: drop all peers, recovery, node restart, periodic sends across the restart | PASSED, exit 0. Both node instances propagate. |
| Same scenario under the ASAN refc build (`-d:useMalloc -fsanitize=address`, `detect_leaks=0`) | PASSED, 0 AddressSanitizer reports |
| TUI in a pty (driven with `expect`): render, footer stats, send + propagated + echo received, node health tables, config table + editor, scenario run from the TUI, log-level menu (mouse and keyboard), F2 / Enter, F3, F9, F10 | all working; F10 exit 0 |
