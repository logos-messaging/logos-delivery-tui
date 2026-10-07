## Log control: runtime log level (chronicles runtime filtering) and the
## optional --log-file tee. Records keep going to stdout as logos-delivery's
## `setupLog` arranged; in TUI mode illview captures fd 1/2 from there.

{.push raises: [].}

import std/strutils
import chronicles, chronicles/topics_registry
import logos_delivery
import logos_delivery/waku/common/logging as ld_logging
import ./tui_brokers

type LogCtl = ref object
  level: LogLevel
  override: string ## --log-level from the CLI, re-applied on every node create
  file: File
  hasFile: bool

var gLog {.threadvar.}: LogCtl

proc logCtl(): LogCtl =
  if gLog.isNil:
    gLog = LogCtl(level: LogLevel.INFO)
  gLog

proc currentLogLevel*(): string =
  $logCtl().level

proc parseLevel*(s: string): Result[LogLevel, string] =
  try:
    ok(parseEnum[LogLevel](s.strip.toUpperAscii))
  except ValueError:
    err("unknown log level: " & s)

proc setLevel*(level: LogLevel) =
  topics_registry.setLogLevel(level)
  logCtl().level = level

proc openLogFile*(path: string): Result[void, string] =
  let c = logCtl()
  try:
    c.file = open(path, fmAppend)
    c.hasFile = true
    ok()
  except IOError as e:
    err("cannot open log file " & path & ": " & e.msg)

proc closeLogFile*() =
  let c = logCtl()
  if c.hasFile:
    c.hasFile = false
    try:
      c.file.close()
    except CatchableError:
      discard

proc teeOutput(idx: static int) =
  ## Wrap the writer `setupLog` just installed so records also reach the file.
  let orig = defaultChroniclesStream.outputs[idx].writer
  defaultChroniclesStream.outputs[idx].writer =
    proc(logLevel: LogLevel, msg: LogOutputStr) {.gcsafe, raises: [].} =
      orig(logLevel, msg)
      {.cast(gcsafe).}:
        let c = gLog
        if not c.isNil and c.hasFile:
          try:
            c.file.write(msg)
            c.file.flushFile()
          except CatchableError:
            discard

proc afterNodeCreate*(ld: LogosDelivery) =
  ## `Waku.new` re-runs `setupLog` (level from the node config, writers to
  ## stdout); take that as our state, then re-apply our overrides.
  let c = logCtl()
  c.level = ld.waku.conf.logLevel
  if c.override.len > 0:
    let lvl = parseLevel(c.override).valueOr:
      LogLevel.INFO
    setLevel(lvl)
  if c.hasFile:
    when defaultChroniclesStream.outputs.type.arity == 2:
      case ld.waku.conf.logFormat
      of ld_logging.LogFormat.TEXT:
        teeOutput(0)
      of ld_logging.LogFormat.JSON:
        teeOutput(1)

proc init*(cliLevel: string) =
  let c = logCtl()
  c.override = cliLevel
  # Writers for the time before the first node exists (the dynamic sink has
  # none); `Waku.new` installs its own on every create.
  ld_logging.setupLog(LogLevel.INFO, ld_logging.LogFormat.TEXT)
  if cliLevel.len > 0:
    let lvl = parseLevel(cliLevel).valueOr:
      LogLevel.INFO
    setLevel(lvl)
  discard TuiSetLogLevel.setProvider(
    tuiCtx,
    proc(level: string): Result[void, string] =
      let lvl = ?parseLevel(level)
      setLevel(lvl)
      # an explicit pick from the UI / scenario also survives node restarts
      logCtl().override = $lvl
      ok(),
  )

{.pop.}
