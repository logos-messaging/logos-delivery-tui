## Configuration views' controller: the started node's configuration with
## the source of each value, and the network presets (conf_resolve.nim); the
## LogosDeliveryNodeConf options for Node management (node_conf.nim).

{.push raises: [].}

import results
import logos_delivery
import ../app/node_host
import chronicles
import ./[tui_brokers, conf_resolve, node_conf, log_ctl]

template quietBuilds(body: untyped): untyped =
  ## The config builder logs every build ("No node key provided, generated a
  ## new one", the sharding summary, ignored-flag warnings); these builds are
  ## the table's, not the node's. They are synchronous on this thread, so the
  ## level is lowered only for their duration.
  let saved = parseLevel(currentLogLevel()).valueOr(LogLevel.INFO)
  setLevel(LogLevel.ERROR)
  try:
    body
  finally:
    setLevel(saved)

proc init*() =
  discard TuiStartedConfig.setProvider(
    tuiCtx,
    proc(): Result[StartedConfig, string] =
      let h = host()
      if h.startedJson.len == 0:
        return ok(StartedConfig())
      var res = StartedConfig(
        started: true, running: h.isRunning, json: h.startedJson,
        nodeConf: h.startedNodeConf,
      )
      quietBuilds:
        res.preset =
          if h.startedNodeConf: nodeConfPresetOf(h.startedJson)
          else: presetOf(h.startedJson)
        let rows =
          if h.startedNodeConf: nodeConfEffectiveRows(h.startedJson, h.startedConf)
          else: effectiveRows(h.startedJson, h.startedConf)
        if rows.isOk:
          res.rows = rows.get
        else:
          res.error = rows.error
      ok(res),
  )
  discard TuiPresets.setProvider(
    tuiCtx,
    proc(): Result[seq[PresetInfo], string] =
      ok(presets()),
  )
  discard TuiActivePreset.setProvider(
    tuiCtx,
    proc(confJson: string): Result[string, string] =
      ok(activePreset(confJson)),
  )
  discard TuiNodeOptions.setProvider(
    tuiCtx,
    proc(confJson: string): Result[seq[NodeOptionRow], string] =
      nodeOptionRows(confJson),
  )
  discard TuiNodeConfPatch.setProvider(
    tuiCtx,
    proc(
        confJson: string, cli: string, valueJson: string, append: bool, reset: bool
    ): Result[ConfigPatch, string] =
      let patched = quietBuilds:
        patchNodeConf(confJson, cli, valueJson, append, reset)
      let (json, message) = ?patched
      ok(ConfigPatch(json: json, message: message)),
  )
  discard TuiNodeConfFrom.setProvider(
    tuiCtx,
    proc(text: string): Result[ConfigPatch, string] =
      let (json, message) = ?toNodeConfJson(text)
      ok(ConfigPatch(json: json, message: message)),
  )

{.pop.}
