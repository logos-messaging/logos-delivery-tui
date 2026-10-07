## Saved node configs and scenarios. Default location is XDG
## ($XDG_CONFIG_HOME or ~/.config)/logos-delivery-tui/{nodes,scenarios};
## any path given explicitly is used as-is.

{.push raises: [].}

import std/[os, strutils]
import results

const AppDir = "logos-delivery-tui"

const DefaultNodeConf* = """{
  "preset": "logos.test",
  "mode": "Core"
}
"""

proc configRoot*(): string =
  getConfigDir() / AppDir

proc savedDir*(kind: string): string =
  ## kind: "nodes" | "scenarios"
  configRoot() / kind

proc resolveSavePath*(kind, nameOrPath: string): string =
  ## A bare name goes to the XDG dir (".json" appended); a path is kept.
  if nameOrPath.contains(DirSep) or nameOrPath.startsWith("."):
    nameOrPath
  else:
    let n = if nameOrPath.endsWith(".json"): nameOrPath else: nameOrPath & ".json"
    savedDir(kind) / n

proc saveText*(path, content: string): Result[void, string] =
  try:
    let dir = path.parentDir
    if dir.len > 0:
      createDir(dir)
    writeFile(path, content)
    ok()
  except CatchableError as e:
    err("cannot write " & path & ": " & e.msg)

proc loadText*(path: string): Result[string, string] =
  try:
    ok(readFile(path))
  except CatchableError as e:
    err("cannot read " & path & ": " & e.msg)

proc listSaved*(kind: string): seq[string] =
  try:
    for f in walkFiles(savedDir(kind) / "*.json"):
      result.add f
  except CatchableError:
    discard

{.pop.}
