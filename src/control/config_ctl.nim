## Configuration views' controller: the effective node configuration (presets
## merged, value sources), the network presets, and patching values into the
## node config JSON (conf_resolve.nim); the LogosDeliveryNodeConf options for
## Node management (node_conf.nim).

{.push raises: [].}

import results
import logos_delivery
import logos_delivery/waku/factory/waku_conf
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
  discard TuiCurrentConfig.setProvider(
    tuiCtx,
    proc(confJson: string): Result[seq[KV], string] =
      # Running: what the node uses, sourced against the config it was started
      # with. Stopped: what the editor's config would give.
      let h = host()
      quietBuilds:
        if h.isRunning and h.nodeConf:
          runningRows(h.ld.waku.conf) # no LogosDeliveryConf to source against
        elif h.isRunning:
          effectiveRows(h.confJson, h.ld.waku.conf)
        else:
          effectiveRows(confJson),
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
  discard TuiPatchConfig.setProvider(
    tuiCtx,
    proc(
        confJson: string, cfgKey: string, valueJson: string, append: bool
    ): Result[ConfigPatch, string] =
      let patched = quietBuilds:
        patchConfig(confJson, cfgKey, valueJson, append)
      let (json, message) = ?patched
      ok(ConfigPatch(json: json, message: message)),
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
