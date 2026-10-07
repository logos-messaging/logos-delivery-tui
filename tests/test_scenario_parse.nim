import std/[os, strutils]
import unittest2, results
import ../src/control/scenario

suite "scenario parser":
  test "valid scenario with relative nodeConf":
    let sc = parseScenario("""{
      "name": "t",
      "nodeConf": "node.json",
      "steps": [
        {"action": "waitHealthy", "timeoutS": 5},
        {"action": "subscribe", "contentTopic": "/a/1/b/proto"},
        {"action": "sendPeriodic", "contentTopic": "/a/1/b/proto", "intervalMs": 100, "count": 3},
        {"action": "expect", "metric": "received", "op": ">=", "value": 3}
      ]}""", "/tmp/sc/x.json").get()
    check sc.name == "t"
    check sc.nodeConf == "/tmp/sc" / "node.json"
    check sc.startNode
    check sc.steps.len == 4
    check sc.steps[2].action == Action.sendPeriodic
    check sc.steps[3].params.num("value") == 3

  test "name defaults to file name, startNode can be off":
    let sc = parseScenario("""{"startNode": false, "steps": []}""", "dir/my.json").get()
    check sc.name == "my.json"
    check not sc.startNode

  test "rejects unknown action":
    let r = parseScenario("""{"steps": [{"action": "explode"}]}""")
    check r.isErr
    check "unknown action" in r.error

  test "rejects missing required fields":
    check parseScenario("""{"steps": [{"action": "send"}]}""").isErr
    check parseScenario("""{"steps": [{"action": "sleep", "ms": 0}]}""").isErr
    check parseScenario("""{"steps": [{"action": "sendPeriodic", "contentTopic": "/a"}]}""").isErr
    check parseScenario("""{"steps": [{"action": "expect", "metric": "nope", "value": 1}]}""").isErr
    check parseScenario("""{"steps": [{"action": "expect", "metric": "sent", "op": "=~", "value": 1}]}""").isErr
    check parseScenario("""{"steps": [{"action": "expect", "metric": "sent"}]}""").isErr

  test "rejects malformed documents":
    check parseScenario("not json").isErr
    check parseScenario("[]").isErr
    check parseScenario("""{"name": "x"}""").isErr
    check parseScenario("""{"steps": [1]}""").isErr

  test "payload placeholders":
    let s = expand("#{seq} from {peerId} {rand:5}", 7, "16U")
    check s.startsWith("#7 from 16U ")
    check s.split(' ')[^1].len == 5
    check "{ts}" notin expand("{ts}", 1, "")

  test "comparisons":
    check compare(3, ">=", 3)
    check not compare(2, ">", 2)
    check compare(1, "<", 2)
    check compare(2, "<=", 2)
    check compare(2, "==", 2)
    check compare(2, "!=", 3)
    check not compare(1, "??", 1)

  test "bundled example scenarios parse":
    for f in walkFiles(currentSourcePath.parentDir.parentDir / "conf" / "scenarios" / "*.json"):
      let r = loadScenario(f)
      check r.isOk
      if r.isErr:
        echo f, ": ", r.error
