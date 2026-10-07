## Messaging view: content topic (+ subscribe / unsubscribe), payload editor
## (text, or base64 when ticked), send, and the chat table fed by TuiChatLine.
## Controller: control/messaging_ctl.nim.

{.push raises: [].}

import std/[base64, strutils, tables]
import chronos, results, stew/byteutils
import illview
import ../control/tui_brokers
import ./common

const DefaultContentTopic* = "/logos-delivery-tui/1/chat/proto"
const MaxChatRows = 1000

type MessagingView* = ref object
  page*: Window
  topic: Input
  payload: Editor
  base64Box: Checkbox
  ephemeralBox: Checkbox
  status: Label
  chat: illview.Table
  rowOf: tables.Table[string, int] ## chat key -> row index (outgoing status updates)

proc setStatus(v: MessagingView, s: string) =
  v.status.setText(s)

proc payloadBytes(v: MessagingView): Result[seq[byte], string] =
  let text = v.payload.text
  if v.base64Box.checked:
    try:
      ok(decode(text.strip).toBytes())
    except ValueError as e:
      err("payload is not valid base64: " & e.msg)
  else:
    ok(text.toBytes())

proc doSend(v: MessagingView) {.async: (raises: []).} =
  let topic = v.topic.text.strip
  if topic.len == 0:
    v.setStatus("content topic is empty")
    return
  let payload = v.payloadBytes().valueOr:
    v.setStatus(error)
    return
  let r = await TuiSend.request(tuiCtx, topic, payload, v.ephemeralBox.checked)
  if r.isOk:
    v.setStatus("sent, request " & short(r.get(), 8))
  else:
    v.setStatus("send failed: " & r.error)

proc doSubscribe(v: MessagingView, subscribe: bool) {.async: (raises: []).} =
  let topic = v.topic.text.strip
  if topic.len == 0:
    v.setStatus("content topic is empty")
    return
  let r =
    if subscribe: await TuiSubscribe.request(tuiCtx, topic)
    else: await TuiUnsubscribe.request(tuiCtx, topic)
  let verb = if subscribe: "subscribed" else: "unsubscribed"
  if r.isOk:
    v.setStatus(verb & " " & topic)
  else:
    v.setStatus(verb & " failed: " & r.error)

proc onChatLine(v: MessagingView, e: TuiChatLine) =
  if e.dir == ChatDir.Outgoing and v.rowOf.hasKey(e.key):
    let i = v.rowOf.getOrDefault(e.key)
    if i < v.chat.rows.len:
      var rows = v.chat.rows
      rows[i][4] = $e.status
      v.chat.setRows(rows)
    return
  if e.dir == ChatDir.Incoming and v.rowOf.hasKey(e.key):
    return # same message delivered twice (e.g. live + history)
  var rows = v.chat.rows
  if rows.len >= MaxChatRows:
    rows.delete(0)
    var shifted: tables.Table[string, int]
    for k, i in v.rowOf:
      if i > 0:
        shifted[k] = i - 1
    v.rowOf = shifted
  rows.add @[e.ts, $e.dir, e.contentTopic, e.text, $e.status]
  v.rowOf[e.key] = rows.high
  v.chat.setRows(rows)
  v.chat.select(rows.high)

proc newMessagingView*(): MessagingView =
  let v = MessagingView()
  v.page = pageWindow("Messaging")

  v.topic = newInput(DefaultContentTopic).stretchW()
  v.topic.history = @[DefaultContentTopic]
  let subBtn = newButton("~S~ubscribe")
  let unsubBtn = newButton("~U~nsubscribe")
  subBtn.onClick = proc(b: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      asyncSpawn v.doSubscribe(true)
  unsubBtn.onClick = proc(b: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      asyncSpawn v.doSubscribe(false)

  v.payload = newEditor("hello from logos-delivery-tui")
  v.base64Box = newCheckbox("base64 payload")
  v.ephemeralBox = newCheckbox("ephemeral")
  let sendBtn = newButton("Se~n~d")
  sendBtn.onClick = proc(b: Button) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      asyncSpawn v.doSend()
  v.status = newLabel("").stretchW()

  v.chat = newTable(@[
    tableColumn("time", fixedHint(8)),
    tableColumn("", fixedHint(1)),
    tableColumn("content topic", prefHint(24, stretch = 1)),
    tableColumn("payload", prefHint(30, stretch = 3)),
    tableColumn("status", fixedHint(14)),
  ])
  v.chat.showScrollbar = true

  let body = newVBox(spacing = 0)
  body.dock = dkFill
  body.add row(label("Content topic", 14), v.topic, subBtn, unsubBtn)
  body.add section("Payload", v.payload, height = 4)
  body.add row(v.base64Box, v.ephemeralBox, sendBtn, v.status)
  body.add section("Messages", v.chat)
  v.page.add body

  discard TuiChatLine.listen(
    tuiCtx,
    proc(e: TuiChatLine) {.async: (raises: []).} =
      v.onChatLine(e),
  )
  v

{.pop.}
