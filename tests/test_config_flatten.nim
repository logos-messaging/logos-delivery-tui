import unittest2, results
import ../src/control/conf_flatten

type
  InnerConf = object
    port: int
    host: string

  Wrapped = distinct InnerConf

  OuterConf = ref object
    name: string
    inner: InnerConf
    opt: Opt[InnerConf]
    missing: Opt[int]
    wrapped: Wrapped
    list: seq[string]
    notAConf: tuple[a, b: int]

suite "config flatten":
  test "nested config objects become dotted keys":
    let c = OuterConf(
      name: "n",
      inner: InnerConf(port: 1, host: "h"),
      opt: Opt.some(InnerConf(port: 2, host: "o")),
      missing: Opt.none(int),
      wrapped: Wrapped(InnerConf(port: 3, host: "w")),
      list: @["x", "y"],
      notAConf: (1, 2),
    )
    let rows = flatten(c, "top")
    check rows == @[
      ("top.name", "n"),
      ("top.inner.port", "1"),
      ("top.inner.host", "h"),
      ("top.opt.port", "2"),
      ("top.opt.host", "o"),
      ("top.missing", "none"),
      ("top.wrapped.port", "3"),
      ("top.wrapped.host", "w"),
      ("top.list", "@[\"x\", \"y\"]"),
      ("top.notAConf", "(a: 1, b: 2)"),
    ]

  test "nil ref":
    let c: OuterConf = nil
    check flatten(c, "c") == @[("c", "nil")]
