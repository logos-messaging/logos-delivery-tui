## Messaging view: content topic (+ subscribe / unsubscribe), payload editor
## (text, or base64 when ticked), send, the chat table fed by TuiChatLine and,
## below it, the selected message in detail: from (mine / other party),
## content topic, hash, request id, status, the decoded text and the base64.
## Controller: control/messaging_ctl.nim.

{.push raises: [].}

import std/[base64, strutils, tables]
import chronos, results, stew/byteutils
import illview
import ../control/tui_brokers
import ./common

const DefaultContentTopic* = "/logos-delivery-tui/1/chat/proto"
const MaxChatRows = 1000
const Base64Width = 64 ## base64 lines in the detail view

type
  ChatRec = object
    ## One chat row's message, for the detail view.
    key: string ## request id (outgoing) or message hash (incoming)
    ts: string
    dir: ChatDir
    contentTopic: string
    text: string
    payload: seq[byte]
    msgHash: string
    status: ChatStatus
    error: string

  MessagingView* = ref object
    page*: Window
    topic: Input
    payload: Editor
    base64Box: Checkbox
    ephemeralBox: Checkbox
    status: Label
    chat: illview.Table
    recs: seq[ChatRec] ## row for row with `chat`
    rowOf: tables.Table[string, int] ## chat key -> row index (outgoing status updates)
    # detail of the selected message
    dFrom, dTopic, dHash, dRequest, dStatus, dError: Input ## read-only
    fields: BoxLayout ## the rows above
    errorRow: BoxLayout ## shown for a failed message only
    dTextBox: GroupBox
    dText, dBase64: TextView

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

func oneLine*(text: string): string =
  ## A row of the table: newlines as ⏎ (a CR-LF pair as one).
  text.replace("\r\n", "⏎").replace("\n", "⏎").replace("\r", "⏎")

func errorText*(status: ChatStatus, error: string): string =
  ## The detail pane's error row: what the node said ("" = no row).
  if status != ChatStatus.Error: ""
  elif error.len > 0: error.oneLine
  else: "(no reason given)"

proc showErrorRow(v: MessagingView, text: string) =
  v.errorRow.visible = text.len > 0
  v.dError.show(text)
  v.fields.hint = (v.fields.hint.w, fixedHint(if text.len > 0: 6 else: 5))

func row(r: ChatRec): seq[string] =
  @[r.ts, $r.dir, r.contentTopic, r.text.oneLine, $r.status]

proc showDetail(v: MessagingView) =
  ## Fill the detail pane from the selected row (cleared when none).
  let i = v.chat.selected
  v.dText.clear()
  v.dBase64.clear()
  if i < 0 or i >= v.recs.len:
    for l in [v.dFrom, v.dTopic, v.dHash, v.dRequest, v.dStatus]:
      l.show("")
    v.showErrorRow("")
    v.dTextBox.borderTitle = "Decoded text"
    return
  let r = v.recs[i]
  let mine = r.dir == ChatDir.Outgoing
  v.dFrom.show(
    (if mine: "mine  → sent " else: "other party  ← received ") & r.ts
  )
  v.dTopic.show(r.contentTopic)
  v.dHash.show(if r.msgHash.len > 0: r.msgHash else: "… (not known yet)")
  v.dRequest.show(if mine: r.key else: "–")
  v.dStatus.show($r.status)
  v.showErrorRow(errorText(r.status, r.error))
  if r.payload.len > 0 and r.text == "0x" & r.payload.toHex():
    v.dTextBox.borderTitle = "Decoded text (binary, " & $r.payload.len & " bytes)"
    v.dText.addLine("(not text: shown as hex in the list)")
  else:
    v.dTextBox.borderTitle = "Decoded text (" & $r.payload.len & " bytes)"
    for line in r.text.replace("\r\n", "\n").split('\n'):
      v.dText.addLine(line)
  let b64 = encode(r.payload)
  var i64 = 0
  while i64 < b64.len:
    v.dBase64.addLine(b64[i64 ..< min(i64 + Base64Width, b64.len)])
    i64 += Base64Width
  for tv in [v.dText, v.dBase64]: # from the top, not following the end
    tv.follow = false
    tv.top = 0

proc clearChat(v: MessagingView) =
  ## The node stopped: its messages go with it (a restart may join another
  ## network).
  v.recs.setLen(0)
  v.rowOf.clear()
  v.chat.setRows(@[])
  v.showDetail()

proc onChatLine(v: MessagingView, e: TuiChatLine) =
  if e.dir == ChatDir.Outgoing and v.rowOf.hasKey(e.key):
    let i = v.rowOf.getOrDefault(e.key)
    if i < v.recs.len:
      v.recs[i].status = e.status
      v.recs[i].error = e.error
      if e.msgHash.len > 0:
        v.recs[i].msgHash = e.msgHash
      var rows = v.chat.rows
      rows[i] = v.recs[i].row
      v.chat.setRows(rows)
      if v.chat.selected == i:
        v.showDetail()
    return
  if e.dir == ChatDir.Incoming and v.rowOf.hasKey(e.key):
    return # same message delivered twice (e.g. live + history)
  var rows = v.chat.rows
  if rows.len >= MaxChatRows:
    rows.delete(0)
    v.recs.delete(0)
    var shifted: tables.Table[string, int]
    for k, i in v.rowOf:
      if i > 0:
        shifted[k] = i - 1
    v.rowOf = shifted
  let rec = ChatRec(
    key: e.key, ts: e.ts, dir: e.dir, contentTopic: e.contentTopic, text: e.text,
    payload: e.payload, msgHash: e.msgHash, status: e.status,
  )
  v.recs.add rec
  rows.add rec.row
  v.rowOf[e.key] = rows.high
  v.chat.setRows(rows)
  v.chat.select(rows.high) # the newest message, in detail too
  v.showDetail()

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
  v.chat.onSelect = proc(t: illview.Table) {.gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      v.showDetail()

  # detail of the selected message
  proc field(name: string, value: Input): BoxLayout =
    row(label(name, 15), value)
  v.dFrom = newValueField()
  v.dTopic = newValueField()
  v.dHash = newValueField()
  v.dRequest = newValueField()
  v.dStatus = newValueField()
  v.dError = newValueField()
  v.dText = newTextView()
  v.dBase64 = newTextView()
  v.dTextBox = section("Decoded text", v.dText)
  let fields = newVBox(spacing = 0)
  v.fields = fields
  fields.dock = dkTop
  fields.hint = (prefHint(0, stretch = 1), fixedHint(5))
  fields.add field("from", v.dFrom)
  fields.add field("content topic", v.dTopic)
  fields.add field("message hash", v.dHash)
  fields.add field("request id", v.dRequest)
  fields.add field("status", v.dStatus)
  v.errorRow = field("error", v.dError)
  v.errorRow.visible = false
  fields.add v.errorRow
  let base64Box = section("Base64", v.dBase64)
  for box in [v.dTextBox, base64Box]:
    box.styleOv.bg = bgGray # window surface, not the cyan group surface
  let detail = newVBox(spacing = 0)
  detail.add fields
  detail.add newSplitter(axH, v.dTextBox, base64Box)

  let body = newVBox(spacing = 0)
  body.dock = dkFill
  body.add row(label("Content topic", 14), v.topic, subBtn, unsubBtn)
  body.add section("Payload", v.payload, height = 4)
  body.add row(v.base64Box, v.ephemeralBox, sendBtn, v.status)
  # Minimum heights: the divider is clamped against them, whatever size the
  # first layout pass had.
  let list = section("Messages", v.chat)
  list.hint = (prefHint(0, stretch = 1), SizeHint(min: 8, pref: 12, stretch: 1))
  let detailBox = section("Message   select one in the list above", detail)
  detailBox.styleOv.bg = bgGray # labels on the window surface, values as fields
  detailBox.hint = (prefHint(0, stretch = 1), SizeHint(min: 9, pref: 12, stretch: 1))
  body.add newSplitter(axV, list, detailBox)
  v.page.add body

  discard TuiChatLine.listen(
    tuiCtx,
    proc(e: TuiChatLine) {.async: (raises: []).} =
      v.onChatLine(e),
  )
  discard TuiNodeState.listen(
    tuiCtx,
    proc(e: TuiNodeState) {.async: (raises: []).} =
      if e.state == NodeState.Stopped:
        v.clearChat(),
  )
  v

{.pop.}
