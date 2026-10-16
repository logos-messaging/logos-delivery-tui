## Messaging control: send / subscribe / unsubscribe through the messaging API
## layer (`ld.messagingClient`), and a chat stream (`TuiChatLine`) built from
## our sends plus MessageSent/Propagated/Error/Queued/Received events. Our own
## messages coming back on a subscription are not shown again (echo_filter).
##
## Outgoing status: Queued (rate limit) → Propagated → Sent once a store node
## confirms it (reliability on, not ephemeral; else Propagated is final), or
## Error at any point.

{.push raises: [].}

import std/[sets, times, unicode]
import chronos, chronicles, results, stew/byteutils
import brokers/broker_scope
import logos_delivery
import logos_delivery/messaging/api/[send, subscription]
import ../app/node_host
import ./[tui_brokers, echo_filter]

logScope:
  topics = "ldtui messaging"

type MessagingCtl = ref object
  ld: LogosDelivery
  brokerScope: BrokerScope ## the node-event listeners of the attached node
  outgoing: HashSet[string] ## requestIds we sent, to tag their status events
  echoes: EchoFilter ## our sends, to recognise them when they come back

var gMsg {.threadvar.}: MessagingCtl

proc nowTs(): string =
  try:
    now().format("HH:mm:ss")
  except CatchableError:
    ""

proc isText*(payload: seq[byte]): bool =
  ## Valid UTF-8 without control characters other than tab, newline and
  ## carriage return (C0, DEL and C1 are refused: a terminal may act on them,
  ## e.g. U+009B as CSI).
  let s = string.fromBytes(payload)
  if validateUtf8(s) != -1:
    return false
  for r in s.runes:
    let c = r.int32
    if (c < 0x20 and c notin [0x09'i32, 0x0A, 0x0D]) or (c >= 0x7F and c <= 0x9F):
      return false
  true

proc printable*(payload: seq[byte]): string =
  ## Payload as text (newlines kept) when `isText`, otherwise as 0x-hex.
  if payload.isText: string.fromBytes(payload) else: "0x" & payload.toHex()

proc status(c: MessagingCtl, requestId, msgHash: string, st: ChatStatus, error = "") =
  c.echoes.hashKnown(requestId, msgHash)
  if requestId notin c.outgoing:
    return
  TuiChatLine.emit(
    tuiCtx,
    TuiChatLine(
      key: requestId, dir: ChatDir.Outgoing, status: st, error: error, msgHash: msgHash,
      ts: nowTs(),
    ),
  )
  # Propagated is not final: the store confirmation (Sent) follows it when
  # reliability is on. Without it the id stays in the set until detach.
  if st in {ChatStatus.Sent, ChatStatus.Error}:
    c.outgoing.excl requestId

proc send(
    c: MessagingCtl, contentTopic: string, payload: seq[byte], ephemeral: bool
): Future[Result[string, string]] {.async: (raises: []).} =
  if c.ld.isNil:
    return err("node is not running")
  ?c.ld.ensureMessaging()
  let env = MessageEnvelope.init(ContentTopic(contentTopic), payload, ephemeral)
  let reqId =
    try:
      ?(await c.ld.messagingClient.send(env))
    except CatchableError as e:
      return err("send failed: " & e.msg)
  let key = $reqId
  c.outgoing.incl key
  c.echoes.sent(key, contentTopic, payload)
  TuiChatLine.emit(
    tuiCtx,
    TuiChatLine(
      key: key,
      dir: ChatDir.Outgoing,
      contentTopic: contentTopic,
      text: printable(payload),
      payload: payload,
      status: ChatStatus.Pending,
      ts: nowTs(),
    ),
  )
  ok(key)

proc attach(c: MessagingCtl, ld: LogosDelivery) =
  c.ld = ld
  c.brokerScope = newBrokerScope(ld.waku.brokerCtx)
  discard MessageSentEvent.listen(
    c.brokerScope,
    proc(e: MessageSentEvent) {.async: (raises: []).} =
      c.status($e.requestId, e.messageHash, ChatStatus.Sent),
  )
  discard MessagePropagatedEvent.listen(
    c.brokerScope,
    proc(e: MessagePropagatedEvent) {.async: (raises: []).} =
      c.status($e.requestId, e.messageHash, ChatStatus.Propagated),
  )
  discard MessageErrorEvent.listen(
    c.brokerScope,
    proc(e: MessageErrorEvent) {.async: (raises: []).} =
      warn "message error", requestId = $e.requestId, error = e.error
      c.status($e.requestId, e.messageHash, ChatStatus.Error, e.error),
  )
  discard MessageQueuedEvent.listen(
    c.brokerScope,
    proc(e: MessageQueuedEvent) {.async: (raises: []).} =
      c.status($e.requestId, e.messageHash, ChatStatus.Queued),
  )
  discard MessageReceivedEvent.listen(
    c.brokerScope,
    proc(e: MessageReceivedEvent) {.async: (raises: []).} =
      if c.echoes.isEcho(e.messageHash, $e.message.contentTopic, e.message.payload):
        return # our own message: its outgoing row already shows it
      TuiChatLine.emit(
        tuiCtx,
        TuiChatLine(
          key: e.messageHash,
          dir: ChatDir.Incoming,
          contentTopic: $e.message.contentTopic,
          text: printable(e.message.payload),
          payload: e.message.payload,
          msgHash: e.messageHash,
          status:
            if e.source == MessageSource.History: ChatStatus.History
            else: ChatStatus.Live,
          ts: nowTs(),
        ),
      ),
  )

proc detach(c: MessagingCtl) {.async: (raises: []).} =
  if c.ld.isNil:
    return
  await c.brokerScope.close()
  c.outgoing.clear()
  c.echoes.clear()
  c.ld = nil

proc init*() =
  let c = MessagingCtl()
  gMsg = c
  host().onAttach(
    proc(ld: LogosDelivery) {.gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        c.attach(ld)
  )
  host().onDetach(
    proc() {.async: (raises: []).} =
      {.cast(gcsafe).}:
        await c.detach()
  )
  discard TuiSend.setProvider(
    tuiCtx,
    proc(
        contentTopic: string, payload: seq[byte], ephemeral: bool
    ): Future[Result[string, string]] {.async.} =
      (await c.send(contentTopic, payload, ephemeral)),
  )
  discard TuiSubscribe.setProvider(
    tuiCtx,
    proc(contentTopic: string): Future[Result[void, string]] {.async.} =
      if c.ld.isNil:
        return err("node is not running")
      ?c.ld.ensureMessaging()
      try:
        ?(await c.ld.messagingClient.subscribe(ContentTopic(contentTopic)))
      except CatchableError as e:
        return err("subscribe failed: " & e.msg)
      info "subscribed", contentTopic
      ok(),
  )
  discard TuiUnsubscribe.setProvider(
    tuiCtx,
    proc(contentTopic: string): Future[Result[void, string]] {.async.} =
      if c.ld.isNil:
        return err("node is not running")
      ?c.ld.ensureMessaging()
      ?c.ld.messagingClient.unsubscribe(ContentTopic(contentTopic))
      info "unsubscribed", contentTopic
      ok(),
  )

{.pop.}
