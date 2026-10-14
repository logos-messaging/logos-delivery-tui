## Log pane filter: rules over chronicles text-format records.
##
## A record is `LVL date time message  key=value key="quoted value" ...`.
## A filter is a list of rules joined by AND / OR, AND binding tighter: the
## rules split at every OR into groups, and a record passes when every rule of
## some group matches. Text comparisons ignore case.

{.push raises: [].}

import std/[json, strutils]
import results

type
  LogLevel* = enum
    llTrace = "TRC"
    llDebug = "DBG"
    llInfo = "INF"
    llNotice = "NTC"
    llWarn = "WRN"
    llError = "ERR"
    llFatal = "FAT"

  LogRecord* = object
    line*: string
    hasLevel*: bool ## false: not a record start (continuation, other output)
    level*: LogLevel
    msg*: string
    props*: seq[(string, string)] ## key, unquoted value; in line order

  LogField* = enum
    lfLevel = "level"
    lfMsg = "msg"
    lfTopics = "topics"
    lfFile = "file"
    lfTid = "tid"
    lfKey = "key" ## the property named by `Rule.key`
    lfLine = "line"

  LogOp* = enum
    opContains = "contains"
    opNotContains = "!contains"
    opEquals = "="
    opNotEquals = "≠"
    opAtLeast = "≥" ## level only
    opAtMost = "≤" ## level only

  Join* = enum
    jAnd = "AND"
    jOr = "OR"

  Rule* = object
    join*: Join ## to the rule before (ignored on the first)
    field*: LogField
    key*: string ## property name when `field == lfKey`
    op*: LogOp
    value*: string

  LogFilter* = object
    rules*: seq[Rule]
    enabled*: bool

# --- parsing -------------------------------------------------------------------

func parseLevel*(s: string): (bool, LogLevel) =
  ## "WRN", "warn", "warning", "W" ... -> level.
  let u = s.strip.toUpperAscii
  if u.len == 0:
    return (false, llTrace)
  for l in LogLevel:
    if u == $l:
      return (true, l)
  const names = [("TRACE", llTrace), ("DEBUG", llDebug), ("INFO", llInfo),
    ("NOTICE", llNotice), ("WARN", llWarn), ("WARNING", llWarn), ("ERROR", llError),
    ("FATAL", llFatal)]
  for (n, l) in names:
    if u == n:
      return (true, l)
  for (n, l) in names:
    if n.startsWith(u):
      return (true, l) # a prefix: "W" -> WARN
  (false, llTrace)

func isKeyChar(c: char): bool =
  c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '.', '-'}

func propAt(s: string, i: int, key, value: var string): int =
  ## A `key=value` token starting at `i`: its end, or -1.
  var j = i
  while j < s.len and s[j].isKeyChar:
    inc j
  if j == i or j >= s.len or s[j] != '=' or not (s[i] in {'a' .. 'z', 'A' .. 'Z', '_'}):
    return -1
  key = s[i ..< j]
  inc j
  value = ""
  if j < s.len and s[j] == '"':
    inc j
    while j < s.len and s[j] != '"':
      if s[j] == '\\' and j + 1 < s.len:
        inc j
      value.add s[j]
      inc j
    if j >= s.len:
      return -1 # unterminated: not a property
    inc j
  else:
    while j < s.len and s[j] != ' ':
      value.add s[j]
      inc j
  if j < s.len and s[j] != ' ':
    return -1
  j

func parseRecord*(line: string): LogRecord =
  result.line = line
  if line.len < 4 or line[3] != ' ':
    return
  let (ok, lvl) = parseLevel(line[0 .. 2])
  if not ok or line[0 .. 2] != $lvl:
    return
  result.hasLevel = true
  result.level = lvl
  # skip the date and time tokens
  var i = 4
  for _ in 0 .. 1:
    while i < line.len and line[i] != ' ': inc i
    while i < line.len and line[i] == ' ': inc i
  # tokens: the properties are the longest run of key=value tokens at the end
  var starts: seq[int]
  var props: seq[(string, string)] # parsed from each token start, "" key = word
  var j = i
  while j < line.len:
    while j < line.len and line[j] == ' ': inc j
    if j >= line.len: break
    var k, v: string
    let e = propAt(line, j, k, v)
    starts.add j
    if e > 0:
      props.add (k, v)
      j = e
    else:
      props.add ("", "")
      while j < line.len and line[j] != ' ': inc j
  var first = props.len
  while first > 0 and props[first - 1][0].len > 0:
    dec first
  let msgEnd = if first < starts.len: starts[first] else: line.len
  result.msg = line[i ..< msgEnd].strip
  result.props = props[first .. ^1]

func prop*(r: LogRecord, key: string): (bool, string) =
  for (k, v) in r.props:
    if cmpIgnoreCase(k, key) == 0:
      return (true, v)
  (false, "")

# --- matching ------------------------------------------------------------------

func fieldValue(r: LogRecord, rule: Rule): (bool, string) =
  case rule.field
  of lfLevel: (r.hasLevel, if r.hasLevel: $r.level else: "")
  of lfMsg: (r.hasLevel, r.msg)
  of lfTopics: r.prop("topics")
  of lfFile: r.prop("file")
  of lfTid: r.prop("tid")
  of lfKey: r.prop(rule.key)
  of lfLine: (true, r.line)

func matches*(rule: Rule, r: LogRecord): bool =
  let (present, v) = r.fieldValue(rule)
  let want = rule.value.strip
  case rule.op
  of opContains: present and v.toLowerAscii.contains(want.toLowerAscii)
  of opNotContains: not (present and v.toLowerAscii.contains(want.toLowerAscii))
  of opEquals: present and cmpIgnoreCase(v, want) == 0
  of opNotEquals: not (present and cmpIgnoreCase(v, want) == 0)
  of opAtLeast, opAtMost:
    let (ok, lvl) = parseLevel(want)
    if rule.field != lfLevel or not r.hasLevel or not ok:
      false
    elif rule.op == opAtLeast:
      r.level >= lvl
    else:
      r.level <= lvl

func active*(f: LogFilter): bool =
  f.enabled and f.rules.len > 0

func matches*(f: LogFilter, r: LogRecord): bool =
  ## AND binds tighter than OR: true when every rule of some OR-group matches.
  if not f.active:
    return true
  var group = true
  for i, rule in f.rules:
    if i > 0 and rule.join == jOr:
      if group:
        return true
      group = true
    group = group and rule.matches(r)
  group

func describe*(rule: Rule): string =
  let name = if rule.field == lfKey: (if rule.key.len > 0: rule.key else: "key?") else: $rule.field
  let v = if rule.value.contains(' ') or rule.value.len == 0: "\"" & rule.value & "\"" else: rule.value
  name & " " & $rule.op & " " & v

func describe*(f: LogFilter): string =
  for i, rule in f.rules:
    if i > 0:
      result.add " " & $rule.join & " "
    result.add rule.describe

# --- a stream of lines ---------------------------------------------------------

type LineVerdicts* = object
  ## Per-stream state: a line that is not a record start (a stack trace, a
  ## wrapped value) shares the verdict of the record above it.
  inRecord: bool
  last: bool

proc pass*(v: var LineVerdicts, f: LogFilter, line: string): bool =
  let r = parseRecord(line)
  if not r.hasLevel and v.inRecord:
    return v.last
  v.inRecord = r.hasLevel
  v.last = f.matches(r)
  v.last

proc countMatches*[T](f: LogFilter, lines: T): int =
  ## How many of `lines` (a seq or a Deque) the filter shows.
  var v: LineVerdicts
  for l in lines:
    if v.pass(f, l):
      inc result

# --- saved filters -------------------------------------------------------------

func toJson*(f: LogFilter): string =
  var rules = newJArray()
  for r in f.rules:
    rules.add %*{"join": $r.join, "field": $r.field, "key": r.key, "op": $r.op,
                 "value": r.value}
  (%*{"rules": rules}).pretty

proc fromJson*(text: string): Result[LogFilter, string] =
  ## Saved filters come back enabled.
  try:
    let j = parseJson(text)
    var f = LogFilter(enabled: true)
    for r in j["rules"]:
      f.rules.add Rule(
        join: parseEnum[Join](r{"join"}.getStr("AND")),
        field: parseEnum[LogField](r["field"].getStr),
        key: r{"key"}.getStr,
        op: parseEnum[LogOp](r["op"].getStr),
        value: r{"value"}.getStr,
      )
    ok(f)
  except CatchableError as e:
    err("not a log filter: " & e.msg)

{.pop.}
