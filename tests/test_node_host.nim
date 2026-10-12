import std/json
import unittest2, chronos, results
import ../src/app/node_host

suite "started config snapshot":
  test "a failed start leaves the snapshot alone":
    let h = host()
    h.startedJson = """{"preset": "logos.test"}"""
    let r = waitFor h.start("""{"entry-layer": "kernel", "mode": "Core"}""", nodeConf = true)
    check:
      r.isErr
      h.startedJson == """{"preset": "logos.test"}""" # unchanged
      h.confJson == """{"entry-layer": "kernel", "mode": "Core"}"""
      h.nodeConf
