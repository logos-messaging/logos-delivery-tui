## Current configuration as a flat k/v table. The rows come from the
## LogosDeliveryConf the host's JSON resolves to (kernel / messaging /
## channels layers), so presets and defaults are visible too, not just the
## keys present in the file.

{.push raises: [].}

import std/json
import results
import logos_delivery
import logos_delivery/api/conf/logos_delivery_conf_json
import ../app/node_host
import ./[tui_brokers, conf_flatten]

proc currentConfig*(confJson: string): Result[seq[KV], string] =
  let conf = parseLogosDeliveryConf(confJson).valueOr:
    return err("invalid node configuration: " & error)
  var rows: seq[FlatKV]
  flattenInto(rows, "kernel", conf.kernelConf)
  flattenInto(rows, "messaging", conf.messagingConf)
  flattenInto(rows, "channels", conf.channelsConf)
  var res: seq[KV]
  for (k, v) in rows:
    res.add KV(key: k, value: v)
  ok(res)

proc prettyJson*(confJson: string): string =
  try:
    parseJson(confJson).pretty()
  except CatchableError:
    confJson

proc init*() =
  discard TuiCurrentConfig.setProvider(
    tuiCtx,
    proc(): Result[seq[KV], string] =
      currentConfig(host().confJson),
  )

{.pop.}
