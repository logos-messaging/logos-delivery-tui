import std/strutils
import unittest2, stew/byteutils
import ../src/control/[echo_filter, messaging_ctl]

const Topic = "/logos-delivery-tui/1/chat/proto"

suite "own messages coming back":
  test "echo before the hash is known: matched by topic + payload, once":
    var f: EchoFilter
    f.sent("req1", Topic, "hello".toBytes)
    check:
      f.isEcho("0xaa", Topic, "hello".toBytes)
      f.isEcho("0xaa", Topic, "hello".toBytes) # live, then history: still ours
      not f.isEcho("0xbb", Topic, "hello".toBytes) # a second, foreign "hello"

  test "echo after the hash is known: matched by hash":
    var f: EchoFilter
    f.sent("req1", Topic, "hi".toBytes)
    f.hashKnown("req1", "0xcc")
    check:
      not f.isEcho("0xdd", Topic, "hi".toBytes) # same text, other message
      f.isEcho("0xcc", Topic, "hi".toBytes)

  test "other topics and payloads are not ours":
    var f: EchoFilter
    f.sent("req1", Topic, "hello".toBytes)
    check:
      not f.isEcho("0x01", "/other/1/t/proto", "hello".toBytes)
      not f.isEcho("0x02", Topic, "hello!".toBytes)

  test "two identical sends: each echo matches one":
    var f: EchoFilter
    f.sent("req1", Topic, "ping".toBytes)
    f.sent("req2", Topic, "ping".toBytes)
    check:
      f.isEcho("0x11", Topic, "ping".toBytes)
      f.isEcho("0x12", Topic, "ping".toBytes)
      not f.isEcho("0x13", Topic, "ping".toBytes)

suite "payload text":
  test "UTF-8 text is shown as text, binary as hex":
    check:
      printable("Szia! Árvíztűrő tükörfúrógép 🙂".toBytes) == "Szia! Árvíztűrő tükörfúrógép 🙂"
      printable(@[0x00'u8, 0xff]) == "0x00ff"
      printable("a\u009b31mb".toBytes).startsWith("0x") # C1 CSI: shown as hex
      printable("tab\tok".toBytes) == "tab\tok"
