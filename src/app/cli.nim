## Command line:
##   logos_delivery_tui [--node-conf=<file.json>] [--scenario=<file.json>]
##                      [--headless] [--log-level=INFO|DEBUG|TRACE|...]
##                      [--log-file=<path>] [--report=<path.jsonl>]
##                      [--autostart=true|false]

{.push raises: [].}

import std/[parseopt, strutils]
import results

type CliConf* = object
  nodeConf*: string
  scenario*: string
  headless*: bool
  logLevel*: string
  logFile*: string
  report*: string
  autostart*: bool
  help*: bool

const Usage* = """
logos_delivery_tui - terminal UI / headless scenario runner for logos-delivery

Usage:
  logos_delivery_tui [options]

Options:
  --node-conf=<file>   Node config JSON (same shape as liblogosdelivery /
                       delivery-module createNode: {"preset":"logos.test",...}).
  --scenario=<file>    Scenario JSON to load (TUI) or run (headless).
  --headless           No TUI: logs to the terminal, runs the scenario (if any)
                       and exits with 0 on PASS, 1 on FAIL. Without a scenario
                       the node runs until Ctrl-C.
  --log-level=<lvl>    TRACE|DEBUG|INFO|NOTICE|WARN|ERROR (overrides the conf).
  --log-file=<path>    Also append node logs to this file.
  --report=<path>      Headless: write scenario progress as JSON lines here.
  --autostart=<bool>   Start the node at launch when a config is given
                       (default true).
  -h, --help           This text.

Hotkeys (TUI): F2 terminal mode (Enter returns), F3 log pane, F9 sidebar,
               F10 quit.
"""

proc parseBoolArg(key, val: string): Result[bool, string] =
  case val.toLowerAscii
  of "", "true", "yes", "1", "on": ok(true)
  of "false", "no", "0", "off": ok(false)
  else: err("invalid boolean for --" & key & ": " & val)

proc parseCli*(args: seq[string]): Result[CliConf, string] =
  var c = CliConf(autostart: true)
  var p = initOptParser(args)
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "node-conf": c.nodeConf = val
      of "scenario": c.scenario = val
      of "headless": c.headless = ?parseBoolArg(key, val)
      of "log-level": c.logLevel = val
      of "log-file": c.logFile = val
      of "report": c.report = val
      of "autostart": c.autostart = ?parseBoolArg(key, val)
      of "h", "help": c.help = true
      else: return err("unknown option: --" & key)
    of cmdArgument:
      return err("unexpected argument: " & key)
    of cmdEnd:
      discard
  if c.headless and c.nodeConf.len == 0 and c.scenario.len == 0:
    return err("--headless needs --node-conf and/or --scenario")
  ok(c)

{.pop.}
